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
    * `:install` — a `Candil.Build` plan describing how to obtain the
      binary. `nil` or `strategy: :none` means "it is already there".
      precompiled binary from the llama.cpp GitHub releases (default: `true`)
    * `:precompiled_version` — `:latest` or a specific release tag such as
      `"b4561"` (default: `:latest`)
    * `:host` — host the server listens on (default: `"127.0.0.1"`)
    * `:port` — base port; each running instance uses this port plus an offset
      (default: `8080`)
    * `:start_args` — extra CLI arguments passed to `llama-server` at startup
      (e.g. `["--n-gpu-layers", "35"]`)
    * `:launcher` — module implementing `Candil.Engine.Launcher` to start
      the engine out-of-band (systemd, docker, another process). When set,
      Candil does NOT spawn `llama-server` itself and does NOT download the
      binary. Default: `nil` (default: Candil owns the binary lifecycle).

  See `Candil.Engine.Launcher` for the custom-launcher contract.
  """

  @type alias :: atom()

  alias Candil.Build
  alias Candil.Engine.Server
  alias Candil.{EnginePool, Installer}

  @enforce_keys [:alias]

  defstruct alias: nil,
            # Where the binary is, and how to get it if it is not there yet.
            binary: nil,
            binary_dir: nil,
            install: nil,
            precompiled_version: :latest,
            checksum_sha256: nil,
            # Networking. `base_port` is the first port `:auto` will hand out;
            # `port` is the fixed port for an external engine.
            host: "127.0.0.1",
            base_port: 10_000,
            port: 8080,
            # Authentication. See `auth_headers/1` for why this lives here.
            api_key: nil,
            auth_headers: [],
            start_args: [],
            launcher: nil

  @type version :: :latest | binary()

  @type api_key :: nil | binary() | {:system, binary()}

  @type t :: %__MODULE__{
          alias: atom(),
          binary: binary() | nil,
          binary_dir: binary() | nil,
          install: Candil.Build.t() | nil,
          precompiled_version: version(),
          checksum_sha256: binary() | nil,
          host: binary(),
          base_port: :inet.port_number(),
          port: :inet.port_number(),
          api_key: api_key(),
          auth_headers: [{binary(), binary()}],
          start_args: [binary()],
          launcher: module() | nil
        }

  @doc """
  Validates an engine struct. Returns `:ok` or `{:error, [reasons]}`.

  Called by `Candil.Store.register_engine/1` before the entry is written, so
  an engine that could never start is rejected at registration rather than at
  the first `Candil.Engine.start/2`.
  """
  @spec validate(t()) :: :ok | {:error, [binary()]}
  def validate(%__MODULE__{} = engine) do
    errors =
      []
      |> validate_install(engine)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp validate_install(errors, %__MODULE__{install: nil}), do: errors

  defp validate_install(errors, %__MODULE__{install: install}) do
    case Build.validate(install) do
      [] -> errors
      problems -> Enum.reverse(problems) ++ errors
    end
  end

  @doc """
  Resolves the engine's API key to a plain string.

  `{:system, "VAR"}` reads `VAR` from the environment at call time, not at
  compile time and not at struct-build time, so a key exported after the
  application boots is still found. A `nil` key and an unset variable both
  return `nil`, which callers treat as "no authentication".

  ## Examples

      iex> Candil.Engine.api_key(%Candil.Engine{alias: :e})
      nil

      iex> Candil.Engine.api_key(%Candil.Engine{alias: :e, api_key: "sk-local"})
      "sk-local"

      iex> System.put_env("CANDIL_TEST_KEY", "from-env")
      iex> Candil.Engine.api_key(%Candil.Engine{alias: :e, api_key: {:system, "CANDIL_TEST_KEY"}})
      "from-env"
  """
  @spec api_key(t()) :: binary() | nil
  def api_key(%__MODULE__{api_key: {:system, var}}) when is_binary(var) do
    case System.get_env(var) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  def api_key(%__MODULE__{api_key: key}) when is_binary(key) and key != "", do: key
  def api_key(%__MODULE__{}), do: nil

  @doc """
  The HTTP headers needed to talk to this engine, including authentication.

  This is the fix for the single most consequential bug in the 3.x line. The
  local inference path used to send a fixed empty header list, so any
  `llama-server` started with `--api-key` answered **401** and there was no
  way to inject one: the options map had no header field to put them in.

  That is not a ropero quirk. Passing `--api-key` is the normal way to run a
  `llama-server` that is not on loopback, and every such server was
  unreachable from Candil. It is also why a consumer of this library ended up
  writing its own HTTP client to work around it.

  Returns `[]` when the engine has no key, so the default behaviour is
  unchanged and a server started without `--api-key` still works.
  """
  @spec auth_headers(t()) :: [{binary(), binary()}]
  def auth_headers(%__MODULE__{} = engine) do
    case api_key(engine) do
      nil -> engine.auth_headers
      key -> [{"authorization", "Bearer " <> key} | engine.auth_headers]
    end
  end

  @doc """
  The base URL and auth headers for a model served by this engine.

  Prefer this over `base_url/1`, which knows nothing about authentication and
  will get you a 401. It is deprecated and kept for one release.
  """
  @spec base_url_and_headers(t(), pos_integer()) :: {binary(), [{binary(), binary()}]}
  def base_url_and_headers(%__MODULE__{host: host} = engine, port) do
    {"http://#{host}:#{port}", auth_headers(engine)}
  end

  @doc """
  Returns the effective binary directory for an engine.

  Falls back to `~/.candil/llm/bin` when `binary_dir` is `nil`.

  Raises `ArgumentError` if the configured path contains `..` (path traversal).
  """
  @spec binary_dir(t()) :: binary()
  def binary_dir(%__MODULE__{binary_dir: nil}) do
    Path.join([System.user_home!(), ".candil", "llm", "bin"])
  end

  def binary_dir(%__MODULE__{binary_dir: dir}) do
    if String.contains?(dir, "..") do
      raise ArgumentError, "binary_dir must not contain path traversal (..): #{inspect(dir)}"
    end

    dir
  end

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

  If the engine declares an `:install` plan and the binary does not exist,
  this function installs it before starting. If `engine.launcher` is set, the
  launcher is invoked instead and Candil never spawns the binary itself — see
  `Candil.Engine.Launcher`.

  Registers the running server in `Candil.Registry` under the model alias.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start(t(), Candil.Model.t()) :: {:ok, pid()} | {:error, binary()}
  def start(%__MODULE__{} = engine, %Candil.Model{} = model) do
    do_start(engine, model)
  end

  defp do_start(%__MODULE__{} = engine, %Candil.Model{} = model) do
    cond do
      engine.launcher != nil ->
        register_start_result(start_via_launcher(engine, model), engine)

      binary_exists?(engine) ->
        register_start_result(start_via_server(engine, model), engine)

      installable?(engine) ->
        case Installer.download_engine(engine) do
          :ok -> do_start(engine, model)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, "Binary not found at #{binary_path(engine)}. Run Candil.download_engine/1."}
    end
  end

  defp installable?(%__MODULE__{install: nil}), do: false
  defp installable?(%__MODULE__{install: %{strategy: :none}}), do: false
  defp installable?(%__MODULE__{}), do: true

  defp register_start_result(res, engine) do
    case res do
      {:ok, pid} ->
        EnginePool.put(engine)
        {:ok, pid}

      :ok ->
        EnginePool.put(engine)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_via_server(%__MODULE__{} = engine, %Candil.Model{} = model) do
    Server.start_link(%{engine: engine, model: model})
  end

  defp start_via_launcher(%__MODULE__{} = engine, %Candil.Model{} = model) do
    case engine.launcher.launch(engine, model) do
      {:ok, %{base_url: base_url, pid: external_pid}} ->
        child_spec =
          {Candil.Engine.Server.External,
           %{base_url: base_url, pid: external_pid, engine: engine, model: model}}

        case DynamicSupervisor.start_child(Candil.EngineSupervisor, child_spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
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
