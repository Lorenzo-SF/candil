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
  """
  @spec candidates(atom()) :: [atom()]
  def candidates(consumer) do
    case pinned(consumer) do
      {:ok, model_alias} ->
        [model_alias]

      :error ->
        configured = configured_models(consumer)

        case configured do
          [] -> default_candidate(consumer)
          list -> list
        end
    end
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        case Enum.find([:models, :model_default], &(Atom.to_string(&1) == key)) do
          nil -> {String.to_atom(key), value}
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
    |> Enum.map(&model_alias!/1)
  end

  defp default_candidate(consumer) do
    case settings(consumer)[:model_default] do
      nil -> []
      alias -> [model_alias!(alias)]
    end
  end

  # El TOML da `"coder"` y el resto del router compara con `:coder`. Sin esta
  # conversion el candidato es un string, no casa con nada, y el unico sintoma
  # es que el router no encuentra modelos que si estan cargados.
  defp model_alias!(alias) when is_atom(alias), do: alias
  defp model_alias!(alias) when is_binary(alias), do: String.to_existing_atom(alias)
  defp model_alias!(alias), do: alias

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
