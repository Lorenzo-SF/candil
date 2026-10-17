defmodule Candil.Agents.ModelBasedReflex do
  @moduledoc """
  The type 2 of the taxonomy: a reflex with a model of the world — state that
  lives in the process, and survives it.

  Type 1 (`Candil.Agents.SimpleReflex`) answers each stimulus as if it had
  never been asked anything before. This one does not: what it has seen, where
  it is and what it paid live in its `GenServer` (`docs/04-modulos/05-agentes`
  §5.1, type 2), and that state is the same `Candil.Agent` state the engine
  threads through `step/3` — the reducer, kept.

  ## The turn

  `evaluate/2` gives the agent a stimulus and lets it work one whole turn —
  one or more `step/3` rounds, tools included — under the same deadline as
  the type 1: the work goes in a `Task`, and past `:timeout` (60 s by
  default) it is killed and the caller receives `{:error, :timeout, []}`.
  `rounds` is a per-turn budget here: in `run/3` the counter dies with the
  run, and a process that lives would otherwise run out of steps once and for
  all.

  ## The restart, for real

  After every finished turn the state is written down
  (`Candil.Agents.Snapshots`, keyed by `:name` — which is why the name is
  required here, and not decoration). When the process
  crashes, the supervisor raises it again with the same arguments, the new
  process finds the last stable state and continues from it: that is the
  restart Arrea cannot do — its workers are `:temporary` and store no state.
  `status/1` says `restored: true` when the process that answers was born
  from a snapshot.

  A snapshot that does not restore is refused at start-up
  (`{:error, {:snapshot_invalid, reason}}`): coming back without state is
  degraded; coming back with half of one is wrong.

  ## The name, and the door

  The same name that keys the snapshot is the door: the process registers in
  `Candil.Registry` on start, so it can be found and asked by it
  (`Candil.Agents.whereis/1`, `Candil.Agents.call/3`, F5.5). The registration
  follows the process — a restart re-registers, and a duplicate name does not
  start a second agent: `{:error, {:already_started, pid}}`.

  ## What it is not

  It does not use `Candil.Context` sessions: its memory is its state, and its
  state is what the snapshot keeps. The `:session` door F5.2 opened is for
  callers driving `run/3`; the day this process needs it, it is a
  pass-through.
  """

  use GenServer

  alias Candil.Agent
  alias Candil.Agents.Breaker
  alias Candil.Agents.Breakers
  alias Candil.Agents.Snapshots

  # El default del motor (`agent.ex`), y aquí igual: una vuelta puede usar
  # herramientas, que es medio punto del tipo 2. El tipo 1 baja a 1 porque un
  # reflejo decide una vez; este recuerda, y recuerda también sus pasos.
  @default_max_steps 8
  @default_timeout 60_000

  @typedoc """
  What `evaluate/2` returns: a `t:Candil.Agent.result/0` for the turn, or the
  deadline running out in the same shape.
  """
  @type result :: Agent.result()

  @doc """
  Starts the agent.

  ## Options

    * `:backend` — **required**: the `Candil.Backend` module it talks to.
      Without it the process does not start (`{:error, :no_backend}`).
    * `:name` — **required**: the agent's identity. It keys the snapshot
      (`Candil.Agents.Snapshots`) and it is the door (F5.5): the process
      registers and can be found and called by it (`Candil.Agents.call/3`).
      Without it, `{:error, :no_name}`.
    * `:goal` — the goal; it goes in the system prompt (no `:goal`, no system
      message — the same as `Candil.Agent`).
    * `:model` — the model alias; `"default"` when not given. Checked against
      the catalogue before the process is born: an alias that is not there is
      `{:error, {:model_not_up, alias}}`, and not an agent that fails on
      every call.
    * `:max_steps` — max rounds **per turn**; 8 by default.
    * `:timeout` — deadline in ms for the whole turn; 60 000 by default.
    * `:breaker_threshold` — consecutive hangs that close the door;
      `5` by default. See `Candil.Agents.Breaker` (§8.3).
    * `:breaker_cooldown_ms` — cooldown before the probe is let through;
      `30 000` by default.

  A name whose last stable state is stored comes back from it instead of
  starting empty; a stored state that does not restore does not start at all
  (`{:error, {:snapshot_invalid, reason}}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Las tres puertas van aquí, antes de nacer, y no en `init/1` por lo mismo
    # que en el tipo 1 (F5.3): un `init/1` que devuelve `{:stop, …}` deja
    # señal de salida y se lleva por delante a quien llama desde un
    # `start_link` directo. Comprobado aquí, el proceso ni nace.
    with {:ok, backend} <- resolve_backend(opts),
         {:ok, name} <- resolve_name(opts),
         {:ok, engine, restored?} <- initial_engine(opts, backend, name) do
      # Con nombre —obligatorio aqui— y registrado en el `start_link`, no en
      # `init/1`: el nombre duplicado es un `{:error, {:already_started,
      # pid}}` de la puerta (F5.5), sin proceso a medias.
      GenServer.start_link(__MODULE__, {opts, engine, restored?}, name: Candil.Agents.via(name))
    end
  end

  # El child spec explícito, como el del tipo 1: el que se cae vuelve
  # (`:permanent` — y ahora vuelve CON su estado, que es la diferencia de la
  # F5.4) y al parar el árbol hay cinco segundos de gracia.
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
  One stimulus, one whole turn: the agent works (`step/3` rounds, tools and
  all) until the turn ends, from the state of the previous turn and for the
  next one.

  Returns what `Candil.Agent.run/3` returns for the turn — `{:ok, answer,
  trace}` | `{:error, reason, trace}`, three elements also in error — with
  the trace of THIS turn; `status/1` has the trace of the agent's whole life.
  Or `{:error, :timeout, []}` when the turn does not end within the agent's
  deadline, in which case the state stays where it was. Whoever has the name
  and not the server asks through `Candil.Agents.call/3`.
  """
  @spec evaluate(GenServer.server(), term()) :: result()
  def evaluate(server, input) do
    # El plazo del `call` es infinito por lo mismo que en el tipo 1: el único
    # que puede matar la vuelta es el agente, así que el plazo vive dentro.
    GenServer.call(server, {:evaluate, input}, :infinity)
  end

  @doc """
  The model of the world, in numbers: where the agent is (`rounds` of the
  last turn, and its `last` content), what it has seen (`messages`), what it
  has done (`trace`), and whether this process was born from a snapshot
  (`restored`).
  """
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init({opts, engine, restored?}) do
    name = Keyword.fetch!(opts, :name)

    breaker =
      case Breakers.load(name) do
        {:ok, b} -> b
        {:error, :not_found} -> Breaker.new(opts)
      end

    {:ok,
     %{
       name: name,
       engine: engine,
       timeout: Keyword.get(opts, :timeout, @default_timeout),
       restored: restored?,
       breaker: breaker
     }}
  end

  @impl true
  def handle_call({:evaluate, input}, _from, state) do
    # El tercer cerrojo del §8.3, el mismo que en el tipo 1 y por el mismo
    # motivo: con el circuito abierto la vuelta ni empieza. El breaker NO va
    # en el snapshot —es salud del proceso, no estado del mundo—: un agente
    # restaurado nace con el circuito cerrado, y eso es lo que se quiere.
    case Breaker.check(state.breaker, now()) do
      :open ->
        {:reply, {:error, {:agent_circuit_open, state.name}, []}, state}

      _cerrado_o_sonda ->
        # `rounds` se reinicia por vuelta: en `run/3` el contador nace con la
        # llamada, y este proceso vive. Sin esto, `max_steps` sería un tope de
        # por vida y la vuelta que agotase el presupuesto lo agotaría para
        # siempre.
        engine = %{state.engine | rounds: 0}
        task = Task.async(fn -> turn(engine, input) end)

        {reply, state} =
          case Task.yield(task, state.timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, {engine, reply}} ->
              Snapshots.save(state.name, Agent.snapshot(engine))
              {reply, %{state | engine: engine}}

            nil ->
              # El plazo mató la vuelta, no al agente: el estado se queda donde
              # estaba —el último estado estable es el de la última vuelta que
              # terminó— y el snapshot no se toca.
              {{:error, :timeout, []}, state}
          end

        breaker = Breaker.record(state.breaker, Breaker.verdict(reply), now())

        Breakers.save(state.name, breaker)

        {:reply, reply, %{state | breaker: breaker}}
    end
  end

  def handle_call(:status, _from, state) do
    engine = state.engine

    {:reply,
     %{
       name: state.name,
       goal: engine.config[:goal],
       backend: engine.backend,
       model: engine.model,
       max_steps: engine.max_steps,
       timeout: state.timeout,
       restored: state.restored,
       rounds: engine.rounds,
       messages: length(engine.messages),
       trace: length(engine.trace),
       last: last_final(engine.trace),
       breaker: Breaker.check(state.breaker, now())
     }, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # Una vuelta entera: `step/3` hasta el `:final`. El estímulo va en el
  # primer paso y `nil` después — con `nil`, `record_input/2` no añade nada,
  # que es como el motor evita repetir el mensaje de usuario en cada vuelta.
  @spec turn(Agent.agent_state(), term()) :: {Agent.agent_state(), result()}
  defp turn(engine, input) do
    drive(engine, input, length(engine.trace))
  end

  @spec drive(Agent.agent_state(), term(), non_neg_integer()) ::
          {Agent.agent_state(), result()}
  defp drive(engine, input, before) do
    # Solo `{:ok, …}`: es el contrato REAL de este `step/3` — el error de
    # motor viaja como `:final` con el error dentro, que es dato — y es el
    # mismo trato que le da el reductor del motor (`drive/2`, `agent.ex`).
    # Si un día un paso devolviese `{:error, …}` —el callback lo permite—,
    # esto revienta, el supervisor levanta al agente y el snapshot lo
    # restaura: ruidoso y sin pérdida.
    case Agent.step(engine, input, []) do
      {:ok, engine, %{kind: :thought}} ->
        drive(engine, nil, before)

      {:ok, engine, %{kind: :final}} ->
        # La traza que se contesta es la de ESTA vuelta: la de la vida entera
        # del agente es asunto de `status/1`. Y el mapeo de traza a resultado
        # es el de `run/3` (`Candil.Agent.finalize/1`), no una copia.
        {engine, Agent.finalize(Enum.drop(engine.trace, before))}
    end
  end

  @spec last_final(Agent.trace()) :: term() | nil
  defp last_final(trace) do
    trace
    |> Enum.reverse()
    |> Enum.find(&match?(%{kind: :final}, &1))
    |> case do
      nil -> nil
      %{kind: :final, content: content} -> content
    end
  end

  @spec resolve_backend(keyword()) :: {:ok, module()} | {:error, :no_backend}
  defp resolve_backend(opts) do
    case Keyword.get(opts, :backend) do
      backend when is_atom(backend) and not is_nil(backend) -> {:ok, backend}
      _ -> {:error, :no_backend}
    end
  end

  # Un tipo 2 sin nombre no tiene dónde guardar su último estado: el nombre
  # es la identidad y la clave del snapshot. El tipo 1 lo llevaba de adorno;
  # aquí es obligatorio.
  @spec resolve_name(keyword()) :: {:ok, term()} | {:error, :no_name}
  defp resolve_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> {:error, :no_name}
      name -> {:ok, name}
    end
  end

  # El estado inicial viene de uno de dos sitios: del snapshot que dejó la
  # vida anterior de este nombre, o de `init_agent/1` si es su primera vida.
  # Los dos fallos posibles del restore son distintos a propósito: que no
  # haya snapshot es normal —vuelve vacío, pero vuelve—; que el que hay no se
  # pueda restaurar es un dato roto, y para el arranque en la puerta.
  @spec initial_engine(keyword(), module(), term()) ::
          {:ok, Agent.agent_state(), boolean()} | {:error, term()}
  defp initial_engine(opts, backend, name) do
    case Snapshots.load(name) do
      {:ok, snapshot} ->
        case Agent.restore(snapshot) do
          {:ok, engine} -> {:ok, engine, true}
          {:error, reason} -> {:error, {:snapshot_invalid, reason}}
        end

      {:error, :not_found} ->
        fresh_engine(opts, backend, name)
    end
  end

  @spec fresh_engine(keyword(), module(), term()) ::
          {:ok, Agent.agent_state(), false} | {:error, term()}
  defp fresh_engine(opts, backend, name) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)

    config = %{name: name, goal: Keyword.get(opts, :goal), max_steps: max_steps}

    case Agent.init_agent(
           config: config,
           max_steps: max_steps,
           backend: backend,
           model: Keyword.get(opts, :model) || "default"
         ) do
      {:ok, engine} -> {:ok, engine, false}
      {:stop, reason} -> {:error, reason}
    end
  end

  # El reloj del circuito, el mismo que en el tipo 1: `monotonic` porque un
  # ajuste de hora del sistema no tiene por que abrir ni cerrar un circuito.
  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
