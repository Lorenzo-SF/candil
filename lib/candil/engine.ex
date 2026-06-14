defmodule Candil.Engine do
  @moduledoc """
  Local llama.cpp engine definition and lifecycle management.

  An engine represents a `llama-server` binary that serves a model over an
  OpenAI-compatible HTTP API. Multiple models can be configured to use the
  same engine definition, but only one model can be loaded per running server
  instance.

  ## Fields

    * `:alias` — unique atom identifier for the engine
    * `:binary_dir` — directory where the `llama-server` binary lives or will
      be installed (default: `"~/.apero/llm/bin"`)
    * `:use_precompiled` — if `true`, Apero will download the official
      precompiled binary from the llama.cpp GitHub releases (default: `true`)
    * `:precompiled_version` — `:latest` or a specific release tag such as
      `"b4561"` (default: `:latest`)
    * `:host` — host the server listens on (default: `"127.0.0.1"`)
    * `:port` — base port; each running instance uses this port plus an offset
      (default: `8080`)
    * `:start_args` — extra CLI arguments passed to `llama-server` at startup
      (e.g. `["--n-gpu-layers", "35"]`)
  """

  alias Candil.Engine.Server
  alias Candil.Installer

  @enforce_keys [:alias]

  defstruct alias: nil,
            binary_dir: nil,
            use_precompiled: true,
            precompiled_version: :latest,
            host: "127.0.0.1",
            port: 8080,
            start_args: []

  @type version :: :latest | binary()

  @type t :: %__MODULE__{
          alias: atom(),
          binary_dir: binary() | nil,
          use_precompiled: boolean(),
          precompiled_version: version(),
          host: binary(),
          port: :inet.port_number(),
          start_args: [binary()]
        }

  @doc """
  Returns the effective binary directory for an engine.

  Falls back to `~/.apero/llm/bin` when `binary_dir` is `nil`.
  """
  @spec binary_dir(t()) :: binary()
  def binary_dir(%__MODULE__{binary_dir: nil}) do
    Path.join([System.user_home!(), ".apero", "llm", "bin"])
  end

  def binary_dir(%__MODULE__{binary_dir: dir}), do: dir

  @doc """
  Returns the full path to the `llama-server` binary for this engine.
  """
  @spec binary_path(t()) :: binary()
  def binary_path(%__MODULE__{} = engine) do
    Path.join(binary_dir(engine), "llama-server")
  end

  @doc """
  Returns `true` if the engine binary exists on disk.
  """
  @spec binary_exists?(t()) :: boolean()
  def binary_exists?(%__MODULE__{} = engine) do
    File.exists?(binary_path(engine))
  end

  @doc """
  Starts a `llama-server` process loaded with `model`.

  If `engine.use_precompiled` is `true` and the binary does not exist,
  this function automatically downloads it before starting.

  Registers the running server in `Candil.Registry` under the model alias.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start(t(), Candil.Model.t()) :: {:ok, pid()} | {:error, binary()}
  def start(%__MODULE__{} = engine, %Candil.Model{} = model) do
    do_start(engine, model)
  end

  defp do_start(%__MODULE__{} = engine, %Candil.Model{} = model) do
    cond do
      binary_exists?(engine) ->
        Server.start_link(%{engine: engine, model: model})

      engine.use_precompiled ->
        case Installer.download_engine(engine) do
          :ok -> do_start(engine, model)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, "Binary not found at #{binary_path(engine)}. Run Candil.download_engine/1."}
    end
  end

  @doc """
  Stops the engine server running the given model alias.

  Returns `:ok` or `{:error, :not_running}`.
  """
  @spec stop(atom()) :: :ok | {:error, :not_running}
  def stop(model_alias) when is_atom(model_alias) do
    case Registry.lookup(registry(), model_alias) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal)
        :ok

      [] ->
        {:error, :not_running}
    end
  end

  @doc """
  Returns `true` if the engine serving `model_alias` is running and responding
  to the `/health` endpoint.
  """
  @spec healthy?(atom()) :: boolean()
  def healthy?(model_alias) when is_atom(model_alias) do
    case Registry.lookup(registry(), model_alias) do
      [{pid, _}] ->
        case GenServer.call(pid, :health, 5_000) do
          :ok -> true
          _ -> false
        end

      [] ->
        false
    end
  end

  @doc """
  Returns the base URL for the engine serving `model_alias`, or `nil` if not
  running.
  """
  @spec base_url(atom()) :: binary() | nil
  def base_url(model_alias) when is_atom(model_alias) do
    case Registry.lookup(registry(), model_alias) do
      [{pid, _}] -> GenServer.call(pid, :base_url)
      [] -> nil
    end
  end

  @doc """
  Returns the Registry module used for engine registration.

  Defaults to `Candil.Registry`. Can be configured via:

      config :candil, :registry, MyApp.CustomRegistry

  """
  @spec registry() :: module()
  def registry do
    Application.get_env(:candil, :registry, Candil.Registry)
  end
end
