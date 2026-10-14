defmodule Candil.Telemetry.Quality do
  @moduledoc """
  Las dos señales de calidad, **con su retardo distinto y declarado**.

  ## Por que dos y no una

  | señal | detecta | retardo | muestra |
  |---|---|---|---|
  | **`finish_reason` anómalo** | un modelo **roto** | ninguno | decenas |
  | **reintento** | un modelo **sutilmente peor** | la ventana | cientos |

  Son complementarias y no intercambiables. `finish_reason == "length"` quiere
  decir que la respuesta se quedó sin tokens a medio hacer: es un fallo
  **determinista**, gratis, y se ve en la primera. El reintento detecta «este
  modelo responde pero no tanto como el otro», y eso **no tiene señal directa**:
  es la única pista barata que existe, y llega tarde.

  Con una sola de las dos te quedas cojo: solo con `finish_reason`, un modelo
  que responde mal de forma consistente es invisible. Solo con reintentos,
  tardas días en ver el primer modelo roto.

  ## Y por qué NO hay un bandit aquí

  Porque un bandit necesita una recompensa, y **esta recompensa no es la
  calidad**: es «menos reintentos». Optimizar eso es optimizar «menos veces que
  el usuario se moleste», que es distinto de «mejores respuestas» y mas facil de
  gamingar.

  Este modulo **cuenta y no decide**. La tabla la mira una persona y ajusta la
  configuracion. Es un bucle humano, y es lo que corresponde a este tamano.

  ## La formula, y por que el denominador es este

      retry_rate(model) = retries_atribuidos(model) / served_by(model)

  **El denominador excluye las cache hits.** Una peticion que salio de la cache
  no la sirvio ese modelo: contarla infla el denominador y hunde la tasa de
  todos por igual, **incluida la del modelo malo**. Un modelo que solo recibe
  cache hits pareceria perfecto.

  **Y el reintento es un evento retrasado**, de la peticion *siguiente* y no de la
  actual. Por eso hay `retriable_after/0`: una peticion con menos de eso no se
  puede considerar fallida, porque aun le queda tiempo.

  ## Limitacion que se dice en voz alta

  **No hay `consumer` en la cuenta.** La llamada a inferencia no sabe de que
  consumer viene, asi que dos consumers con el mismo prompt se podrian atribuir
  el reintento el uno al otro. Se corrige en cuanto la llamada lo lleve; hasta
  entonces el numero es una aproximacion, y esta es la frase que hay que leer
  antes de(owner el numero.
  """

  use GenServer

  @handler_id "candil-quality"
  @table __MODULE__
  @remember __MODULE__.Remember

  # Un reintento cuenta solo si la peticion anterior ya tiene edad suficiente
  # para haber recibido uno.
  @retriable_after_ms 30_000

  @anomalies %{
    "length" => "se quedo sin tokens",
    "content_filter" => "el modelo se neguo",
    "error" => "el modelo fallo"
  }

  # ── API ───────────────────────────────────────────────────────────────────

  @doc """
  Las dos señales, por modelo, con el tribunal de calidad calculado.
  """
  @spec snapshot() :: map()
  def snapshot do
    if :ets.whereis(@table) == :undefined do
      empty()
    else
      # El modelo vive en la CLAVE, no en el valor: el valor es el contador.
      # Se lee la tabla entera en vez de usar un match spec: un patron anidado
      # de ETS es dificil de leer y facil de escribir mal —y cuando esta mal,
      # la tabla sale vacia sin fallar nada.
      models =
        @table
        |> :ets.tab2list()
        |> Enum.map(fn
          {{model, _tag}, _n} -> model
          {{model, _tag, _reason}, _n} -> model
        end)
        |> Enum.uniq()
        |> Enum.sort()

      %{per_model: Map.new(models, &{&1, row(&1)}), signals: signals()}
    end
  end

  @doc """
  Los contadores en bruto, sin tasa calculada.

  A proposito hay una via con los numeros y otra con el ratio: una tasa con
  `n = 3` y un `50%` se leen igual que una con mil. Mirar los dos juntos es lo
  que evita decidir sobre una proporcion de cinco cosas.
  """
  @spec signals() :: map()
  def signals do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _ -> :ets.tab2list(@table) |> Enum.into(%{}, fn {k, v} -> {k, v} end)
    end
  end

  defp empty, do: %{per_model: %{}, signals: %{}}

  defp row(model) do
    served = count({model, :served})

    anómalos =
      Enum.map(@anomalies, fn {reason, _} -> count({model, :anomalous, reason}) end) |> Enum.sum()

    retries = count({model, :retries})

    %{
      served: served,
      anomalous: anómalos,
      anomaly_rate: ratio(anómalos, served),
      retries: retries,
      retry_rate: ratio(retries, served)
    }
  end

  defp ratio(_parte, 0), do: 0.0
  defp ratio(parte, total), do: Float.round(parte * 100 / total, 1)

  defp count(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Ventana tras la cual un reintento cuenta. Expuesta para que la tabla diga
  **por que** una peticion aun no ha podido fallar.
  """
  @spec retriable_after() :: pos_integer()
  def retriable_after, do: @retriable_after_ms

  @doc """
  Los `finish_reason` que cuentan como modelo roto.
  """
  @spec anomalies() :: %{String.t() => String.t()}
  def anomalies, do: @anomalies

  @doc """
  Lo cuenta todo, en una tabla de texto.
  """
  @spec format(map()) :: String.t()
  def format(snapshot) do
    per_model = snapshot.per_model

    if map_size(per_model) == 0 do
      """
      CALIDAD POR MODELO

        (aun no ha salido ninguna peticion por el gateway)
      """
    else
      filas =
        per_model
        |> Enum.sort_by(fn {_m, r} -> -r.served end)
        |> Enum.map_join("\n", fn {model, r} ->
          "    #{String.pad_trailing(inspect(model), 14)} #{String.pad_trailing(to_string(r.served), 7)}#{String.pad_trailing(to_string(r.anomalous), 7)}#{String.pad_trailing("#{r.anomaly_rate}%", 8)}#{String.pad_trailing(to_string(r.retries), 6)}#{r.retry_rate}%"
        end)

      """
      CALIDAD POR MODELO

        modelo          servidas  anomalos  %    reintentos  %
      #{filas}

        La senal primaria es **anomalos**: es determinista, sin retardo y con
        pocas muestras. La secundaria es **reintentos**: necesita #{div(@retriable_after_ms, 1000)} s
        de margen y cientos de peticiones para significar algo.

        Mira los dos numeros juntos. Una tasa sobre cinco peticiones no es una
        tasa: es una anecdote.
      """
    end
  end

  # ── proceso ───────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    # Si la telemetria no esta lista todavia —que pasa en el arranque, segun el
    # orden de `EngineLog`— se reintenta en el siguiente arranque. Sin esto, el
    # contador arrancaria mudo y el sintoma seria «no cuenta nada», que es
    # justo el fallo que hay que evitar.
    :telemetry.attach(@handler_id, [:candil, :llm, :chat, :stop], &__MODULE__.on_call/4, nil)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # ── el handler ────────────────────────────────────────────────────────────

  @doc false
  @spec on_call(term(), map(), map(), term()) :: :ok
  def on_call(_event, measurements, meta, _config) do
    if :ets.whereis(@table) != :undefined and meta[:model] do
      bump({meta.model, :served}, 1)
      maybe_anomaly(meta)
      maybe_retry(meta)
    end

    _ = measurements
    :ok
  end

  # `:length` no es un fallo cuando el peticion **pedia** pocos tokens a
  # proposito. Es por eso que esto cuenta y no juzga: el numero dice «tres
  # veces se quedo corto», y quien lo lee decide si eso es un problema.
  defp maybe_anomaly(%{finish_reason: reason, model: model}) when is_binary(reason) do
    if Map.has_key?(@anomalies, reason), do: bump({model, :anomalous, reason}, 1)
  end

  defp maybe_anomaly(_otro), do: :ok

  # Un reintento se atribuye a la peticion ANTERIOR, no a esta. Sin `consumer`,
  # dos consumers con el mismo prompt pueden cruzarse — y por eso el modulo lo
  # dice en el `@moduledoc` en vez de esconderlo detras de un numero bonito.
  defp maybe_retry(%{prompt_hash: nil, model: model}) do
    __MODULE__.Remember.put(@remember, model, nil)
  end

  defp maybe_retry(%{prompt_hash: hash, model: model}) do
    ahora = System.monotonic_time(:millisecond)

    case __MODULE__.Remember.get(@remember, hash) do
      {anterior_model, visto} when is_binary(anterior_model) ->
        if ahora - visto >= @retriable_after_ms do
          bump({anterior_model, :retries}, 1)
        end

        __MODULE__.Remember.put(@remember, hash, {anterior_model, ahora})
        _ = model

      _vacio ->
        __MODULE__.Remember.put(@remember, hash, {model, ahora})
    end
  end

  defp bump(key, by) do
    :ets.update_counter(@table, key, by, {key, 0})
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Pone los contadores a cero. Para medir una ventana concreta.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # El ETS de «ultima peticion por hash» necesita vivir aparte: son claves
  # distintas de las de conteo y su ciclo de vida es otro — caduca, no se
  # reinicia con un `reset/0` del tribunal.
  defmodule Remember do
    @moduledoc false
    @cache 300_000

    def put(table, key, value) do
      ensure(table)
      :ets.insert(table, {key, value, mono()})
    end

    def get(table, key) do
      case :ets.lookup(table, key) do
        [{^key, value, escrito}] ->
          if mono() - escrito <= @cache, do: value, else: nil

        _ ->
          nil
      end
    rescue
      ArgumentError -> nil
    end

    defp ensure(table) do
      if :ets.whereis(table) == :undefined,
        do: :ets.new(table, [:named_table, :public, :set, write_concurrency: true])

      true
    end

    defp mono, do: System.monotonic_time(:millisecond)
  end
end
