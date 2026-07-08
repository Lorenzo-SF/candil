defmodule Candil.Engine.Launcher do
  @moduledoc """
  Behaviour for custom engine launchers.

  By default Candil owns the lifecycle of the `llama-server` OS process:
  `Candil.Engine.start/2` spawns the binary, monitors it, and tears it down
  on `Candil.Engine.stop/1`. Sometimes that is not desirable — the engine
  may be:

    * A non-`llama-server` HTTP service (vLLM, TabbyAPI, text-generation-inference,
      ollama, lm-studio, etc.) that already implements an OpenAI-compatible
      `/v1/...` API.
    * Managed outside the BEAM by an external supervisor (systemd unit,
      docker container, kubernetes pod, a sidecar started by another Erlang
      node).
    * A shared cluster resource that must NOT be killed when Candil stops.

  In all those cases the consumer wants Candil to *talk* to the engine over
  HTTP, but NOT to start or stop it. Implement this behaviour and pass the
  module as `:launcher` on the `%Candil.Engine{}` struct; Candil will call
  `launch/2` instead of spawning `llama-server` itself.

  ## Return contract

    * `{:ok, %{base_url: url, pid: pid_or_nil}}` — Candil will register a
      `Candil.Engine.Server.External` GenServer under the model alias and
      poll `<base_url>/health` every 5 seconds.
    * `{:error, reason}` — propagated verbatim by `Candil.Engine.start/2`.

  ## Fields

    * `base_url` — **required**. Full base URL of the HTTP API
      (e.g. `"http://10.0.0.5:8080"`). Used for `/health` polling and for
      building request URLs to `/v1/chat/completions` and friends.
    * `pid` — **optional**. An OS-process pid that Candil can send
      `:shutdown` to when `Candil.Engine.stop/1` is called. Pass `nil` if
      the process is managed externally and Candil must NOT terminate it
      (e.g. a docker container, a systemd unit). When `nil`, Candil only
      unregisters the Candil-side GenServer on stop.

  ## Example

      defmodule MyApp.SystemdLauncher do
        @behaviour Candil.Engine.Launcher

        @impl true
        def launch(%Candil.Engine{alias: eng_alias}, %Candil.Model{} = _model) do
          # Start or attach to a systemd unit; return its main PID.
          unit_name = Atom.to_string(eng_alias) <> ".service"
          {:ok, pid} = Systemd.start_unit(unit_name)
          {:ok, %{base_url: "http://127.0.0.1:8080", pid: pid}}
        end
      end

      engine = %Candil.Engine{
        alias: :my_llm,
        host: "127.0.0.1",
        port: 8080,
        launcher: MyApp.SystemdLauncher
      }

      :ok = Candil.Engine.start(engine, model)
  """

  alias Candil.{Engine, Model}

  @doc """
  Returns a map describing the (already-running) engine.

  See moduledoc for the return shape.
  """
  @callback launch(Engine.t(), Model.t()) ::
              {:ok, %{base_url: String.t(), pid: pid() | nil}}
              | {:error, term()}
end
