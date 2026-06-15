defmodule Candil.Config do
  @moduledoc """
  Engine and model registry for `Candil.Llm`.

  Stores engine and model definitions in ETS so they can be looked up by
  alias throughout the application. Definitions can be loaded at startup
  from application configuration or registered programmatically at runtime.

  ## Application config

      config :apero, Candil.Config,
        engines: [
          %{
            alias: :llama_server,
            use_precompiled: true,
            precompiled_version: :latest,
            host: "127.0.0.1",
            port: 8080,
            start_args: ["--n-gpu-layers", "35"]
          }
        ],
        models: [
          %{
            alias: :llama3,
            type: :local,
            model_dir: "/models",
            filename: "llama-3-8b-q4_k_m.gguf",
            context_size: 8192,
            engine: :llama_server,
            usage: [:chat, :completion]
          },
          %{
            alias: :gpt4o,
            type: :remote,
            name: "gpt-4o",
            context_size: 128_000,
            provider: :openai,
            usage: [:chat, :completion, :embeddings]
          }
        ],
        providers: [
          %{
            alias: :openai,
            type: :openai,
            base_url: "https://api.openai.com",
            api_key: {:system, "OPENAI_API_KEY"}
          }
        ]

  ## Programmatic registration

      Candil.Config.register_engine(%Candil.Engine{alias: :llama_server, ...})
      Candil.Config.register_model(%Candil.Model{alias: :llama3, ...})
      Candil.Config.register_provider(%Candil.Provider{alias: :openai, ...})

  Values for `:api_key` can be:

    * A plain string `"sk-..."` — used as-is.
    * `{:system, "ENV_VAR"}` — resolved from the environment at lookup time.

  """

  use GenServer

  alias Candil.{Engine, Model, Provider}

  @table_engines :apero_llm_engines
  @table_models :apero_llm_models
  @table_providers :apero_llm_providers

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers an engine definition.

  Overwrites any existing entry with the same alias.
  """
  @spec register_engine(Engine.t()) :: :ok
  def register_engine(%Engine{alias: a} = engine) when is_atom(a) do
    :ets.insert(@table_engines, {a, engine})
    :ok
  end

  @doc """
  Registers a model definition.

  Overwrites any existing entry with the same alias.
  """
  @spec register_model(Model.t()) :: :ok
  def register_model(%Model{alias: a} = model) when is_atom(a) do
    :ets.insert(@table_models, {a, model})
    :ok
  end

  @doc """
  Registers a provider definition.

  Overwrites any existing entry with the same alias.
  """
  @spec register_provider(Provider.t()) :: :ok
  def register_provider(%Provider{alias: a} = provider) when is_atom(a) do
    :ets.insert(@table_providers, {a, provider})
    :ok
  end

  @doc """
  Looks up an engine by alias.

  Returns `{:ok, engine}` or `{:error, :not_found}`.
  """
  @spec get_engine(atom()) :: {:ok, Engine.t()} | {:error, :not_found}
  def get_engine(alias) when is_atom(alias) do
    case :ets.lookup(@table_engines, alias) do
      [{^alias, engine}] -> {:ok, engine}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Looks up a model by alias.

  Returns `{:ok, model}` or `{:error, :not_found}`.
  """
  @spec get_model(atom()) :: {:ok, Model.t()} | {:error, :not_found}
  def get_model(alias) when is_atom(alias) do
    case :ets.lookup(@table_models, alias) do
      [{^alias, model}] -> {:ok, model}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Looks up a provider by alias, resolving `{:system, "ENV_VAR"}` api_key
  values from the environment at lookup time.

  Returns `{:ok, provider}` or `{:error, :not_found}`.
  """
  @spec get_provider(atom()) :: {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(alias) when is_atom(alias) do
    case :ets.lookup(@table_providers, alias) do
      [{^alias, provider}] -> {:ok, resolve_provider(provider)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns all registered engines.
  """
  @spec list_engines() :: [Engine.t()]
  def list_engines do
    @table_engines |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns all registered models.
  """
  @spec list_models() :: [Model.t()]
  def list_models do
    @table_models |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns all registered providers.
  """
  @spec list_providers() :: [Provider.t()]
  def list_providers do
    @table_providers |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Removes an engine registration.
  """
  @spec deregister_engine(atom()) :: :ok
  def deregister_engine(alias) when is_atom(alias) do
    :ets.delete(@table_engines, alias)
    :ok
  end

  @doc """
  Removes a model registration.
  """
  @spec deregister_model(atom()) :: :ok
  def deregister_model(alias) when is_atom(alias) do
    :ets.delete(@table_models, alias)
    :ok
  end

  @doc """
  Removes a provider registration.
  """
  @spec deregister_provider(atom()) :: :ok
  def deregister_provider(alias) when is_atom(alias) do
    :ets.delete(@table_providers, alias)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table_engines, [:named_table, :public, read_concurrency: true])
    :ets.new(@table_models, [:named_table, :public, read_concurrency: true])
    :ets.new(@table_providers, [:named_table, :public, read_concurrency: true])

    load_from_app_config()

    {:ok, %{}}
  end

  defp load_from_app_config do
    cfg = Application.get_env(:apero, __MODULE__, [])

    cfg
    |> Keyword.get(:engines, [])
    |> Enum.each(fn attrs -> register_engine(struct(Engine, atomise_keys(attrs))) end)

    cfg
    |> Keyword.get(:models, [])
    |> Enum.each(fn attrs -> register_model(struct(Model, atomise_keys(attrs))) end)

    cfg
    |> Keyword.get(:providers, [])
    |> Enum.each(fn attrs -> register_provider(struct(Provider, atomise_keys(attrs))) end)
  end

  defp resolve_provider(%Provider{api_key: {:system, env_var}} = provider) do
    %{provider | api_key: System.get_env(env_var)}
  end

  defp resolve_provider(provider), do: provider

  defp atomise_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      case safe_to_atom(k) do
        {:ok, atom} -> Map.put(acc, atom, v)
        :error -> acc
      end
    end)
  end

  defp atomise_keys(list) when is_list(list) do
    Enum.reduce(list, [], fn {k, v}, acc ->
      case safe_to_atom(k) do
        {:ok, atom} -> [{atom, v} | acc]
        :error -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp safe_to_atom(k) when is_atom(k), do: {:ok, k}

  defp safe_to_atom(k) when is_binary(k) do
    {:ok, String.to_existing_atom(k)}
  rescue
    ArgumentError -> :error
  end
end
