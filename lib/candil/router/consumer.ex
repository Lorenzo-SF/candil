defmodule Candil.Router.Consumer do
  @moduledoc """
  Per-consumer settings: which models it may use, and which one wins outright.

  Candidates come from three places, most specific first:

    1. a pin, if `pin/2` was called
    2. `[consumer.X] models` in the config file
    3. the consumer's `model_default`

  The important property is that the list is a *subset* of what exists, not
  "whatever `head/1` returns". A consumer with no models configured gets an
  error, not a model it was never meant to talk to — least of all one whose
  only usage is `:embeddings`.
  """

  use GenServer

  @pinned_table :candil_router_pins

  @doc false
  @spec pinned_table() :: atom()
  def pinned_table, do: @pinned_table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pins a model for a consumer.
  """
  @spec pin(atom(), atom()) :: :ok
  def pin(consumer, model_alias) do
    :ets.insert(@pinned_table, {consumer, model_alias})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Removes a pin.
  """
  @spec unpin(atom()) :: :ok
  def unpin(consumer) do
    :ets.delete(@pinned_table, consumer)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The pinned model, if any.
  """
  @spec pinned(atom()) :: {:ok, atom()} | :error
  def pinned(consumer) do
    case :ets.lookup(@pinned_table, consumer) do
      [{_consumer, model_alias}] -> {:ok, model_alias}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  The model aliases this consumer may use, most preferred first.

  ## Un nombre que no existe es un error, no un crash

  `[consumer.X] models` y `model_default` son **cadenas** en el fichero, y los
  alias son atomos. La conversion tiene que ser `String.to_existing_atom/1` —un
  `to_atom/1` aqui crea un atomo por cada nombre que escriba un fichero, y eso
  es la regla 7—, y a pelo esa funcion **revienta** con `ArgumentError` cuando
  el nombre no esta.

  Medido el 2026-10-15, con un `models = ["coder", "coder_lite"]` cuyo atomo no
  existia todavia:

      ** (ArgumentError) 1st argument: not an already existing atom
      :erlang.binary_to_existing_atom("coder_lite")
      (candil 4.0.0) lib/candil/router/consumer.ex:76: Consumer.candidates/1
      (candil 4.0.0) lib/candil/gateway/handlers/models.ex:25: Models.call/2

  y el cliente recibia un **500 con el cuerpo vacio**, que es lo que peor se
  depura de un gateway. `{:unknown_model, nombre}` en cambio ya sabia pintarse:
  `Gateway.error_body/1` lo convierte en un 400 que nombra el modelo que falta.

  Y no se degrada a los demas candidatos: contestar con un modelo que el
  fichero no ha pedido es la misma falta que el `hd(models)` que este modulo no
  hace — una respuesta a una pregunta que nadie ha hecho.
  """
  @spec candidates(atom()) :: {:ok, [atom()]} | {:error, {:unknown_model, binary()}}
  def candidates(consumer) do
    case pinned(consumer) do
      {:ok, model_alias} ->
        {:ok, [model_alias]}

      :error ->
        case configured_models(consumer) do
          {:ok, []} -> default_candidate(consumer)
          other -> other
        end
    end
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        case Enum.find([:models, :model_default], &(Atom.to_string(&1) == key)) do
          # El TOML es un fichero de texto y sus claves son strings. Crear un
          # atomo por cada clave que aparezca ahi es denegacion de servicio con
          # un fichero de configuracion en la mano.
          nil -> {String.to_existing_atom(key), value}
          atom -> {atom, value}
        end

      other ->
        other
    end)
  end

  defp atomize(other), do: other

  defp configured_models(consumer) do
    consumer
    |> settings()
    |> Map.get(:models, [])
    |> List.wrap()
    |> resolve_aliases()
  end

  defp default_candidate(consumer) do
    case settings(consumer)[:model_default] do
      nil -> {:ok, []}
      name -> resolve_aliases([name])
    end
  end

  # Los nombres del fichero, resueltos a atomos que **existen**. El primero que
  # no exista corta la resolucion: el fichero nombra un modelo que no hay, y
  # seguir con los otros seria contestar con un modelo que nadie ha pedido.
  defp resolve_aliases(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case model_alias(name) do
        {:ok, alias} -> {:cont, {:ok, acc ++ [alias]}}
        {:error, missing} -> {:halt, {:error, {:unknown_model, missing}}}
      end
    end)
  end

  # El TOML da `"coder"` y el resto del router compara con `:coder`. Sin esta
  # conversion el candidato es un string, no casa con nada, y el unico sintoma
  # es que el router no encuentra modelos que si estan cargados.
  #
  # `to_existing_atom/1` **con rescue**, que es el mismo patron que
  # `ChatCompletions.existing_alias/1` y por la misma razon: el nombre viene de
  # un fichero, un `to_atom/1` crearia un atomo por nombre escrito, y un nombre
  # que no esta es una errata que se dice —no una excepcion que se lleva por
  # delante la peticion entera.
  defp model_alias(name) when is_atom(name), do: {:ok, name}

  defp model_alias(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, name}
  end

  defp model_alias(other), do: {:error, inspect(other)}

  # The config file is not parsed until phase 1 wires it up, so this reads
  # from the application environment that config.exs still uses. It keeps the
  # Router's contract testable now without pretending the TOML is wired.
  # De `[consumer.X]` del fichero de configuracion, y no del app env. Estaba en
  # el app env "hasta que la fase 1 conectase el TOML", y ese momento llego y
  # nadie lo cambio: un `[consumer.default] model_default = "coder"` escrito
  # con el toml correcto era INVISIBLE, y el router contestaba
  # `no_models_for_consumer` con un catalogo de siete modelos cargado.
  #
  # Es el mismo disease que `enable_llm_classifier` devolviendo constantes, y
  # sale por el mismo sitio: un flag o un ajuste que parece configurable y no
  # lo esta.
  defp settings(consumer) do
    from_env =
      :candil
      |> Application.get_env(Candil.Router, [])
      |> Keyword.get(:consumers, %{})
      |> Map.get(consumer, %{})

    case Candil.Config.File.load() do
      {:ok, %{"consumer" => consumers}} when is_map(consumers) ->
        # El env gana si esta puesto: es lo que ponen los tests, y un test
        # tiene que poder fijar la configuracion sin escribir un fichero.
        case Map.get(consumers, to_string(consumer)) do
          nil ->
            from_env

          config when map_size(from_env) == 0 ->
            # El TOML da las claves como STRINGS. Buscar `[:model_default]` en
            # `%{"model_default" => "coder"}` devuelve nil, el consumidor se
            # queda sin candidatos y el router contesta
            # `no_models_for_consumer` con siete modelos cargados. Es el mismo
            # fallo que en `[router]`, y en los dos casos el sintoma es
            # "`no_models`" o "`no hace nada`", nunca un error de clave.
            atomize(config)

          _ ->
            from_env
        end

      _ ->
        from_env
    end
  rescue
    _kind ->
      :candil
      |> Application.get_env(Candil.Router, [])
      |> Keyword.get(:consumers, %{})
      |> Map.get(consumer, %{})
  end

  @doc false
  @impl GenServer
  def init(_opts) do
    :ets.new(@pinned_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
