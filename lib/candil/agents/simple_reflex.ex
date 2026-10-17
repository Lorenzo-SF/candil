defmodule Candil.Agents.SimpleReflex do
  @moduledoc """
  The type 1 of the taxonomy: stimulus in, response out, no memory.

  Classifiers and priority routers — one step, one decision, done
  (`docs/04-modulos/05-agentes` §5.1). Each `evaluate/2` is an independent run
  of `Candil.Agent`: nothing of it stays in the process, because a reflex that
  remembered would not be a reflex.

  ## The process, and the work

  The work is `Candil.Agent`'s (F5.2: it is the behaviour's implementation).
  This module is the process around it: it keeps it alive, gives it a
  deadline, and puts it under `Candil.Agents.Supervisor` — which lives in the
  application tree since F5.3.

  ## The name, and the door

  With a `:name` the process registers (`Candil.Registry`, F5.5) and becomes
  findable and callable by it: `Candil.Agents.whereis/1` and
  `Candil.Agents.call/3`. The registration follows the process — a restart
  re-registers, a stop unregisters — and a duplicate name does not fight the
  live one: the second start is `{:error, {:already_started, pid}}`. Without a
  name it still works; it is just not findable.

  ## The deadline, and the day the engine does not come back

  A run ends up talking HTTP, and that HTTP may not come back. A `handle_call`
  that waited for it would stay stuck forever, and whoever called with it.
  Here the run goes in a task of its own and the agent waits with a deadline
  (`:timeout`, 60 s by default): past it, the task is killed — the HTTP dies
  with it — and the answer is `{:error, :timeout, []}`. The agent stays alive
  and serving. That is §8.3 of the agents document, and it has its test.

  ## No memory, for real

  A type 1 accumulates nothing between calls: there is no `:session` here
  (that is the memory door, F5.2), so each run's history dies with its run.
  `status/1` reports what there is — the configuration — and it reads the same
  before and after working.

  ## When it is the code that breaks

  An engine error comes back as data (`{:error, reason, trace}`), but an
  exception raised inside the run is a programming failure: the task and the
  agent are linked, so it takes the agent down with it and the supervisor
  raises it again — a type 1 has nothing to lose. Whoever called notices it as
  an exit.
  """

  use GenServer

  alias Candil.Agent

  @default_max_steps 1
  @default_timeout 60_000

  @typedoc """
  What `evaluate/2` returns: the run's result — three elements also in error,
  like `t:Candil.Agent.result/0` — or the deadline running out, in the same
  shape.
  """
  @type result :: Agent.result()

  @doc """
  Starts the reflex.

  ## Options

    * `:backend` — **required**: the `Candil.Backend` module it talks to.
      Without it the process does not start (`{:error, :no_backend}`): a
      reflex with no engine has nothing to reflect.
    * `:name` — the agent's name. With it the process **registers** and can be
      found and called by it (`Candil.Agents.call/3`, F5.5); without it, it
      still works — it is just not findable. A name already taken by a live
      agent does not start: `{:error, {:already_started, pid}}`.
    * `:goal` — the goal; it goes in the system prompt (no `:goal`, no system
      message — the same as `Candil.Agent`).
    * `:model` — the model alias; `"default"` when not given (the sentinel
      `Candil.Agent` understands, which leaves the engine alone). It is
      checked against the catalogue on every call, so an alias that is not up
      yet lets the process start and fails loudly on `evaluate/2`.
    * `:max_steps` — max rounds; **1** by default: a reflex decides once.
      Raise it for a tool loop — but then it may not be a type 1.
    * `:timeout` — deadline in ms for the whole run; 60 000 by default.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # La comprobación va AQUÍ y no en `init/1`: un `init/1` que devuelve
    # `{:stop, :no_backend}` contesta `{:error, :no_backend}`, sí, pero además
    # el proceso nace enlazado y su señal de salida se lleva por delante a
    # quien llama desde un `start_link` directo (un supervisor la aguanta,
    # porque atrapa salidas; un proceso normal, no). Comprobado aquí, el
    # proceso ni nace y no hay señal que aguantar.
    case Keyword.get(opts, :backend) do
      backend when is_atom(backend) and not is_nil(backend) ->
        GenServer.start_link(__MODULE__, opts, name_opt(opts))

      _ ->
        {:error, :no_backend}
    end
  end

  # El child spec explícito, con los valores que son una decisión (§8.3): el
  # que se cae vuelve (`:permanent` — un tipo 1 no tiene nada que perder) y al
  # parar el árbol hay cinco segundos de gracia, no `:brutal_kill`.
  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Stimulus in, response out. A `call`: the answer arrives, it is not awaited.

  Returns what `Candil.Agent.run/3` returns on each call — `{:ok, answer,
  trace}` | `{:error, reason, trace}` — or `{:error, :timeout, []}` when the
  engine does not come back within the agent's deadline. Whoever has the name
  and not the server asks through `Candil.Agents.call/3`.
  """
  @spec evaluate(GenServer.server(), term()) :: result()
  def evaluate(server, input) do
    # El plazo del `call` es infinito a propósito: el único que puede matar al
    # motor es el agente, así que el plazo vive dentro. Un plazo también aquí
    # obligaría a quien llama a adivinar el del agente — y el agente responde
    # siempre.
    GenServer.call(server, {:evaluate, input}, :infinity)
  end

  @doc """
  The configuration, and nothing else: this agent accumulates nothing to tell.
  """
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    # Sin backend no se llega aquí: `start_link/1` lo corta antes. Si alguien
    # arranca el proceso a mano saltándose la puerta, el estado nace con
    # `backend: nil` y `evaluate/2` contesta `{:error, :no_backend, []}` como
    # `Candil.Agent.run/3` — un dato, no un reventón.
    {:ok,
     %{
       name: Keyword.get(opts, :name),
       goal: Keyword.get(opts, :goal),
       backend: Keyword.get(opts, :backend),
       model: Keyword.get(opts, :model) || "default",
       max_steps: Keyword.get(opts, :max_steps, @default_max_steps),
       timeout: Keyword.get(opts, :timeout, @default_timeout)
     }}
  end

  @impl true
  def handle_call({:evaluate, input}, _from, state) do
    {:reply, within_timeout(state, input), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:name, :goal, :backend, :model, :max_steps, :timeout]), state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # El `:name` es la puerta (F5.5): con nombre, el proceso se registra y se
  # puede encontrar y llamar por el; sin nombre, no — un proceso que solo
  # trabaja no necesita puerta. La registracion va en el `start_link` del
  # `GenServer` y no en `init/1`: asi el nombre duplicado es un
  # `{:error, {:already_started, pid}}` de la puerta, sin proceso a medias.
  @spec name_opt(keyword()) :: keyword()
  defp name_opt(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: Candil.Agents.via(name)]
    end
  end

  # El run va en una tarea propia y se espera con plazo: `Task.yield/2` no
  # bloquea más de la cuenta, y `Task.shutdown/2` mata lo que no volvió —que
  # es también el HTTP que vive dentro de la tarea.
  #
  # El `{:exit, _}` de `Task.yield/2` no tiene rama porque no se alcanza: sin
  # `trap_exit`, un run que revienta se lleva al agente por delante (arriba,
  # «When it is the code that breaks»), así que aquí solo caben un resultado
  # o nada.
  @spec within_timeout(map(), term()) :: result()
  defp within_timeout(state, input) do
    task = Task.async(fn -> Agent.run(config(state), input, run_opts(state)) end)

    case Task.yield(task, state.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout, []}
    end
  end

  @spec config(map()) :: map()
  defp config(state) do
    %{name: state.name, goal: state.goal, max_steps: state.max_steps}
  end

  @spec run_opts(map()) :: keyword()
  defp run_opts(state), do: [backend: state.backend, model: state.model]
end
