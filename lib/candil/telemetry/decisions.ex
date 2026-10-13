defmodule Candil.Telemetry.Decisions do
  @moduledoc """
  Contador de decisiones del router, y el **tribunal** de `DISENO-MOTOR.md` §10.

  ## Que es esto

  `[:candil, :router, :decision]` es el evento: una peticion enrutada, con **la
  capa que produjo la decision**. Esto lo cuenta.

  `§10` del diseño pone una condicion antes de meter un LLM como clasificador:

  > Se mide **que fraccion de decisiones resolvio la politica**. Si es el 97%, al
  > LLM se le llama el 3% y es ruido caro. **Si es el 60%, el motor estatico esta
  > mal hecho** y hay que arreglarlo antes de meter un modelo.

  Y un evento sin lector **no es una metrica**: es una promesa. Sin esto, el
  numero solo existe si alguien escribe un script que se suscribe, y entonces no
  lo mira nadie. Es el mismo fallo que un router sin puerta: la biblioteca llena
  y sin consumidor.

  ## La trampa, y por que el denominador son las PETICIONES

  Hay una gemela de esta en `[:candil, :policy, :turn]`, que emite al **tomar**
  el turno y al **soltarlo**: una peticion que espera son **tres** eventos, no
  dos. Aqui el error es el mismo y **peor, porque no suena**: `decide_by/5` se
  puede llamar hasta cuatro veces en una peticion —reglas, embeddings, LLM—.

  Por eso `DecisionEngine` emite **una vez por `decide/3`**, en el cuello de
  botella, y por eso aqui se cuenta **un evento = una peticion**. Un contador
  puesto en la capa daria un denominador tres o cuatro veces mayor, y el
  porcentaje de LLM mas bajo de lo que es: no un numero grande, **otro numero**.

  Y `:llm_called` va aparte de `:strategy` a proposito. El clasificador puede
  ejecutarse, pagar su inferencia y **no pasar el umbral**: la decision seria
  `:default` con el LLM ya cobrado. Contar solo estrategias diria que el LLM no
  se llamo nunca.

  ## Lo que NO hace

  **No juzga.** Dice cuanto, no que hacer con ello: si el numero es alto, arreglar
  las senales es de quien lo usa, no de este modulo. Un contador que recomienda
  es un modulo que decide por su cuenta.
  """

  use GenServer

  @handler_id "candil-router-decisions"
  @event [:candil, :router, :decision]

  @table __MODULE__
  @key :__counters__

  # ── API ───────────────────────────────────────────────────────────────────

  @doc """
  Lo contado hasta ahora, con el tribunal calculado.

  El mapa trae `total`, `by_strategy`, `llm_called` y `tribunal`.
  """
  @spec snapshot() :: map()
  def snapshot do
    case current() do
      nil -> empty()
      snapshot -> snapshot
    end
  end

  @doc """
  Lo mismo, en texto, para una terminal.
  """
  @spec format(map()) :: String.t()
  def format(snapshot) do
    t = snapshot.tribunal

    """
    DECISIONES DEL ROUTER

      total .................... #{snapshot.total}
      lo resolvio la politica ... #{t.static}/#{snapshot.total} = #{t.static_pct}%
      hubo que llamar al LLM .... #{snapshot.llm_called}/#{snapshot.total} = #{t.llm_pct}%

      quien decidio cada una:
    #{capas(snapshot.by_strategy)}

      Barra de DISENO-MOTOR §10: 60%.
    #{if snapshot.total == 0 do
      "  (sin decisiones todavia)"
    else
      "  VEREDICTO: " <> t.verdict
    end}
    """
  end

  defp capas(%{} = by) when map_size(by) == 0, do: "    (ninguna)"

  defp capas(by) do
    by
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.map_join("\n", fn {capa, n} ->
      "    #{String.pad_trailing(inspect(capa), 12)} #{n}"
    end)
  end

  @doc """
  Puesta a cero. Para medir una ventana concreta sin reiniciar Candil.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(
        @table,
        {@key, %{total: 0, by_strategy: %{}, llm_called: 0, tribunal: tribunal(0, 0)}}
      )
    end

    :ok
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    # El contador arranca en cero **con el tribunal ya calculado**, no con un
    # mapa a medias: `snapshot/0` devolvia `%{tribunal: %{}}` mientras no
    # hubiera llegado ninguna decision, y un lector que hace `tribunal.static`
    # se comia un `KeyError` en el caso mas normal que hay —el de recien
    # arrancar— en vez de un cero.
    :ets.insert(@table, {@key, empty()})

    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # El handler va por ETS y no por el GenServer a proposito: un evento de
  # telemetria que hace un `call` al proceso que lo emite puede montar un ciclo,
  # y contar no es tan urgente como para pagarse ese riesgo.
  @doc false
  def handle_event(_event, _measurements, meta, config) do
    _ = config

    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        %{total: total, by_strategy: by, llm_called: llm} = current()

        nuevo_total = total + 1
        capa = Map.get(meta, :strategy, :desconocida)

        nuevo =
          nuevo_total
          |> then(fn t ->
            %{
              total: t,
              by_strategy: Map.update(by, capa, 1, &(&1 + 1)),
              llm_called: llm + if(meta[:llm_called], do: 1, else: 0),
              tribunal: tribunal(t, llm + if(meta[:llm_called], do: 1, else: 0))
            }
          end)

        :ets.insert(@table, {@key, nuevo})
        :ok
    end
  end

  defp current do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ ->
        :ets.lookup(@table, @key)
        |> List.first()
        |> case do
          {_, snapshot} -> snapshot
          nil -> nil
        end
    end
  end

  defp empty,
    do: %{total: 0, by_strategy: %{}, llm_called: 0, tribunal: tribunal(0, 0)}

  defp tribunal(0, _), do: %{static: 0, static_pct: 0.0, llm_pct: 0.0, verdict: "sin datos"}

  defp tribunal(total, 0),
    do: %{static: total, static_pct: 100.0, llm_pct: 0.0, verdict: "la politica estatica aguanta"}

  defp tribunal(total, llm) do
    estatico = total - llm
    pct_llm = Float.round(llm * 100 / total, 1)
    pct_estatico = Float.round(estatico * 100 / total, 1)

    veredicto =
      cond do
        pct_llm > 30 -> "ARREGLAR LAS SENALES antes de meter un modelo (por encima del 30%)"
        pct_llm > 10 -> "zona intermedia: hay senales debiles"
        true -> "la politica estatica aguanta; el LLM es ruido caro"
      end

    %{static: estatico, static_pct: pct_estatico, llm_pct: pct_llm, verdict: veredicto}
  end

  @doc false
  def event_name, do: @event
end
