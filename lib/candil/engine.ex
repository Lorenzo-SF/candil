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

  alias Candil.{Build, Instances, Model, Store}
  alias Candil.Engine.Server
  alias Candil.{EnginePool, Installer}

  require Logger

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
            # `--cpu`: pone las capas a 0 y quita los flags de dispositivo. No
            # es un `start_args` mas porque hay que REESCRIBIR los que el
            # modelo trae en su `model_args`, y ahi solo se puede llegar desde
            # aqui.
            cpu: false,
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
  The authentication headers for the engine that serves `model_alias`.

  This is the lookup the local inference path uses. It answers "which engine
  is this model on, and what does that engine need to authenticate" in one
  hop, so the three call sites that used to send a literal `[]` cannot forget
  it and cannot get it wrong for one model and right for another.

  Returns `[]` when the model is unknown or has no engine, which is the
  pre-existing behaviour for a server started without `--api-key`.
  """
  @spec auth_headers_for(atom() | String.t()) :: [{binary(), binary()}]
  def auth_headers_for(model_alias) when is_atom(model_alias) or is_binary(model_alias) do
    with {:ok, model} <- fetch_model(model_alias),
         {:ok, engine} <- fetch_engine(model) do
      auth_headers(engine)
    else
      _ -> []
    end
  end

  def auth_headers_for(_model_alias), do: []

  defp fetch_model(model_alias) when is_binary(model_alias) do
    case String.to_existing_atom(model_alias) do
      alias_ -> fetch_model(alias_)
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp fetch_model(model_alias) when is_atom(model_alias) do
    case Store.get_model(model_alias) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp fetch_model(_model_alias), do: {:error, :not_found}

  defp fetch_engine(%{type: :remote, provider: provider}) do
    # A remote model has no engine. Its credentials live on the provider, and
    # the provider path already sends them.
    _ = provider
    {:error, :not_found}
  end

  defp fetch_engine(%{type: :external}), do: {:error, :not_found}

  defp fetch_engine(%{engine: nil}), do: {:error, :not_found}

  defp fetch_engine(%{engine: engine_alias}) do
    case Store.get_engine(engine_alias) do
      {:ok, engine} -> {:ok, engine}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  The base URL and auth headers for the engine serving `model_alias`.

  Prefer this over `base_url/1` on its own, which knows nothing about
  authentication and returns a URL that answers 401.
  """
  @spec connection_for(atom() | String.t()) ::
          {:ok, binary(), [{binary(), binary()}]} | {:error, term()}
  def connection_for(model_alias) do
    with {:ok, model} <- fetch_model(model_alias),
         {:ok, engine} <- fetch_engine(model) do
      case base_url(model_alias) do
        nil -> {:error, :engine_not_running}
        base_url -> {:ok, base_url, auth_headers(engine)}
      end
    else
      _ -> {:error, :engine_not_running}
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

  Falls back to `<data_dir>/llm/bin` when `binary_dir` is `nil`.

  Raises `ArgumentError` if the configured path contains `..` (path traversal).
  """
  @spec binary_dir(t()) :: binary()
  def binary_dir(%__MODULE__{binary_dir: nil}) do
    # `general.data_dir` and not a hardcoded `~/.candil`: a user who moves
    # data_dir to ~/llama was telling us where everything lives, and reading
    # the binary from somewhere else means `models pull` writes where you asked
    # and `candil run` looks somewhere else. Same mistake, two directories.
    Path.join([Instances.data_dir(), "llm", "bin"])
  end

  def binary_dir(%__MODULE__{binary_dir: dir}) do
    guard_no_traversal!(dir, "binary_dir")
    dir
  end

  @doc """
  The engine of `model` as registered, bound to `port`.

  ## Why this function exists

  Three call sites used to build `%Engine{alias: model.engine}` — a struct
  with the alias and **nothing else**: no `binary`, no `install`, no
  `api_key`, no `start_args`, and `port: 8080`, which is the default in the
  defstruct. Every preflight that did it answered "no binary" regardless of
  what the catalogue said. The call sites that did it to actually *start* an
  engine printed `arrancado en :9999` and started nothing: the binary path
  fell back to `<data_dir>/llm/bin/llama-server` and the health check went to
  port 8080.

  None of it raised. `EnginePool.put/5` only starts a GenServer, and a
  GenServer listening on 8080 starts perfectly. The user found it watching
  VRAM with btop — a 27B model that never moved the 47 MB baseline. Every
  smoke test before that had checked exit codes, and `candil run` exits 0
  whether or not a model came up.

  `preflight.ex` had already learned this lesson and carries almost the same
  comment. It just never reached the call sites that start things.
  """
  @spec for_model(term(), pos_integer(), boolean()) :: {:ok, t()} | {:error, :not_found}
  def for_model(model, port, cpu \\ false)

  def for_model(%Model{engine: nil}, _port, _cpu), do: {:error, :not_found}

  def for_model(%Model{engine: alias_name}, port, cpu) do
    case Store.get_engine(alias_name) do
      # El puerto se fija aqui y no en el llamante: el engine del catalogo no
      # sabe que slot se le ha asignado, y `Engine.Server` consulta la salud en
      # `engine.port`.
      {:ok, engine} -> {:ok, %{engine | port: port, cpu: cpu}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def for_model(_model, _port, _cpu), do: {:error, :not_found}

  @doc """
  Returns the full path to the engine binary.

  ## `binary` wins, and it used to be ignored

  `engine.binary` — the key `binary = "..."` in `[engine.<name>]` — is read
  from the config, validated by the schema, stored in the struct, and then
  **never looked at**: this function was `binary_dir/1 <> "llama-server"`, so
  the configured path was reported as missing and, worse, `Engine.Server`
  spawned *that* path instead. A config that names an absolute binary had no
  effect on the process that got run.

  Order: an explicit `binary` is the whole answer, including its filename;
  `binary_dir` is the directory for a standard `llama-server`; and with
  neither, the binary is looked for under `general.data_dir`.
  """
  @spec binary_path(t()) :: binary()
  def binary_path(%__MODULE__{} = engine) do
    case engine.binary do
      nil -> Path.join(binary_dir(engine), "llama-server")
      path -> expand_binary(path)
    end
  end

  defp expand_binary(path) do
    guard_no_traversal!(path, "binary")
    # `~` is expanded because it is a TOML convenience: a config that works
    # for `data_dir` and silently does not for `binary` is a trap.
    Path.expand(path)
  end

  defp guard_no_traversal!(path, field) do
    if String.contains?(path, "..") do
      raise ArgumentError, "#{field} must not contain path traversal (..): #{inspect(path)}"
    end

    path
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
  @spec start(t(), Candil.Model.t(), non_neg_integer() | nil) :: {:ok, pid()} | {:error, term()}
  def start(%__MODULE__{} = engine, %Candil.Model{} = model, device \\ nil) do
    is_cpu = engine.cpu or model.gpu_layers == 0

    # D-27: la reserva va ANTES de `fit-params` para serializar arranques
    # concurrentes. Solo reserva un modelo de GPU que declare `vram_mb`: una
    # estimación por contexto no es una medición (daba 512 MiB para un modelo
    # de 14707) y reservar de menos es peor que no reservar, porque el
    # knapsack acaba afirmando capacidad que no tiene. Sin `vram_mb` el
    # modelo arranca igual —falta planificación, no arranque— y se avisa.
    case acquire(engine, model, is_cpu, device) do
      :skip ->
        start_unreserved(engine, model, device)

      :skip_no_vram ->
        Logger.warning(
          "modelo #{inspect(model.alias)} sin vram_mb: arranca en " <>
            "#{inspect(device)} sin reserva de VRAM"
        )

        start_unreserved(engine, model, device)

      {:ok, _receipt} ->
        start_reserved(engine, model, device)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # El titular de la reserva, en UN sitio. `Engine.start/3` lo usa para
  # reservar y `Server.terminate/2` para liberar; si cada uno lo construyera
  # por su cuenta, un cambio en uno dejaría la reserva de la otra instancia.
  @spec holder(Candil.Model.t(), t()) :: {atom(), non_neg_integer() | nil}
  def holder(%Candil.Model{} = model, %__MODULE__{} = engine) do
    {model.alias, model.port || engine.port}
  end

  defp acquire(engine, model, is_cpu, device) do
    cond do
      # Un motor externo no ocupa esta GPU: no hay nada que reservar.
      engine.launcher != nil -> :skip
      # Un modelo de CPU no pide VRAM.
      is_cpu -> :skip
      # Sin device resuelto no se sabe dónde reservar.
      not is_integer(device) or device < 0 -> :skip
      # `vram_mb` es una declaración, no una estimación: si falta, no se
      # reserva. El modelo arranca; lo que falta es planificación.
      is_nil(model.vram_mb) -> :skip_no_vram
      # `vram_mb: 0` es «este modelo no pide VRAM», no «no lo sé».
      model.vram_mb <= 0 -> :skip
      true -> Candil.Engine.Resource.acquire(device, holder(model, engine), model.vram_mb)
    end
  end

  defp start_unreserved(engine, model, device) do
    {fitted_args, _weight} = fit_params_or_fallback(engine, model, device)
    do_start(engine, model, device, fitted_args)
  end

  defp start_reserved(engine, model, device) do
    holder = holder(model, engine)
    {fitted_args, weight} = fit_params_or_fallback(engine, model, device)

    with :ok <- correct_reservation(device, holder, model.vram_mb, weight) do
      case do_start(engine, model, device, fitted_args) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, reason} ->
          # `init/1` fallido no pasa por `terminate/2`: la reserva se libera
          # aquí, que es el único punto donde sigue en vuelo.
          _ = release_reservation(device, holder)
          {:error, reason}
      end
    end
  end

  # `vram_mb` es un techo declarado, no una medición: la reserva solo sube.
  # Corregir a la baja devolvería capacidad que el motor sigue ocupando; al
  # alza evita el OOM cuando `llama-fit-params` mide más de lo declarado.
  defp correct_reservation(_device, _holder, _declared, weight) when not is_integer(weight),
    do: :ok

  defp correct_reservation(_device, _holder, declared, weight) when weight <= declared, do: :ok

  defp correct_reservation(device, holder, _declared, weight) do
    _ = release_reservation(device, holder)

    case Candil.Engine.Resource.acquire(device, holder, weight) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Un solo dueño para cada reserva: `Engine.start/3` la sostiene mientras el
  # server no existe (un `init/1` fallido no pasa por `terminate/2`); en
  # cuanto `Server.start_link/1` devuelve `{:ok, pid}`, la libera
  # `Server.terminate/2`. Nunca las dos para la misma reserva.
  defp release_reservation(device, holder) do
    if is_integer(device) and device >= 0 do
      Candil.Engine.Resource.release(device, holder)
    else
      :ok
    end
  end

  @doc """
  The **OS** pid of a running engine, or `nil`.

  Not the BEAM pid: `nvidia-smi --query-compute-apps` answers in OS pids, and
  the VRAM a model occupies is only attributable with that one. Ask it while
  the engine is alive —`Arrea.LongRunning`'s registry lives in the VM that
  started it, and a later `candil status` is a different VM—.
  """
  @spec os_pid(pid()) :: pos_integer() | nil
  def os_pid(pid) when is_pid(pid) do
    GenServer.call(pid, :os_pid)
  catch
    :exit, _reason -> nil
  end

  defp do_start(%__MODULE__{} = engine, %Candil.Model{} = model, device, fitted_args) do
    cond do
      engine.launcher != nil ->
        register_start_result(start_via_launcher(engine, model), engine, model)

      binary_exists?(engine) ->
        register_start_result(start_via_server(engine, model, device, fitted_args), engine, model)

      installable?(engine) ->
        case Installer.download_engine(engine) do
          :ok -> do_start(engine, model, device, fitted_args)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, "Binary not found at #{binary_path(engine)}. Run Candil.download_engine/1."}
    end
  end

  defp installable?(%__MODULE__{install: nil}), do: false
  defp installable?(%__MODULE__{install: %{strategy: :none}}), do: false
  defp installable?(%__MODULE__{}), do: true

  defp register_start_result(res, engine, model) do
    case res do
      {:ok, pid} ->
        register_instance(pid, engine, model)
        {:ok, pid}

      :ok ->
        register_instance(nil, engine, model)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fit_params_or_fallback(engine, model, device) do
    case Candil.Engine.FitParams.run(engine, model, device) do
      {:ok, w, args} -> {args, w}
      :fallback -> {nil, nil}
    end
  end

  defp register_instance(pid, engine, model) do
    EnginePool.put(model.alias, instance_port(model, engine), pid, model, engine)
  end

  # `Model.port` is the authority in 4.0 (C8), but `Candil.Engine.Server` still
  # binds to `engine.port`, and `:auto` means nothing until the CLI resolves it
  # (§11.2). So this registers the port the server is actually answering on.
  # When the server moves to the model's port, this clause quietly stops being
  # the one that matches.
  defp instance_port(%Candil.Model{port: port}, %__MODULE__{}) when is_integer(port), do: port
  defp instance_port(_model, %__MODULE__{port: port}), do: port

  defp start_via_server(%__MODULE__{} = engine, %Candil.Model{} = model, device, fitted_args) do
    Server.start_link(%{engine: engine, model: model, device: device, fitted_args: fitted_args})
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

  The `EnginePool` entry goes with it. `start/2` registers there and the
  registry key is only the alias, so a stop that cleaned one and not the other
  left the pool claiming an instance that was no longer running — which is how
  a `status` ends up printing a dead row and `claim_port/2` eventually hands out
  a port that is still in use.
  """
  @spec stop(atom()) :: :ok | {:error, :not_running}
  def stop(model_alias) when is_atom(model_alias) do
    case Registry.lookup(registry(), model_alias) do
      [{pid, _}] ->
        # El server atrapa salidas desde D-27 para poder liberar la reserva en
        # `terminate/2`. Eso abre una carrera con una parada en curso: si el
        # motor ya esta cayendo, `GenServer.stop/3` sale con `:shutdown`/
        # `:noproc` y el engine esta, igualmente, parado. No es un error.
        try do
          GenServer.stop(pid, :normal)
        catch
          # `:noproc` si ya no esta; el `:shutdown` anidado que `:sys.terminate`
          # devuelve cuando otra salida lo esta parando. En los dos casos el
          # engine acaba parado, que es lo que pide `stop/1`.
          :exit, _reason -> :ok
        end

        forget(model_alias)
        :ok

      [] ->
        forget(model_alias)
        {:error, :not_running}
    end
  end

  # The pool is keyed by {alias, port}, so every instance of the model goes,
  # not just the first.
  defp forget(model_alias) do
    EnginePool.list()
    |> Enum.filter(&(&1.alias == model_alias))
    |> Enum.each(&EnginePool.delete(&1.alias, &1.port))
  end

  @doc """
  Returns `true` if the engine serving `model_alias` is running and responding
  to the `/health` endpoint.
  """
  @spec healthy?(atom(), timeout()) :: boolean()
  def healthy?(model_alias, timeout \\ 5_000) when is_atom(model_alias) do
    case Registry.lookup(registry(), model_alias) do
      [{pid, _}] -> health_call(pid, timeout)
      [] -> false
    end
  end

  # El timeout se puede bajar porque se llama en bucle esperando a que un
  # modelo levante. Con cinco segundos por intento, un engine que no responde
  # cuesta cinco segundos en cada vuelta y el bucle entero se va a su
  # presupuesto sin haber comprobado nada nuevo.
  #
  # El `catch` es por el timeout, no por paranoia: un GenServer que no contesta
  # hace que `GenServer.call/3` SALGA, y una salida no es un `false`. Sin
  # atraparla, preguntar la salud de un engine que se ha quedado colgado tumba
  # a quien pregunta —que es el titular, a la espera de un presupuesto
  # entero—.
  defp health_call(pid, timeout) do
    GenServer.call(pid, :health, timeout) == :ok
  catch
    :exit, _reason -> false
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
