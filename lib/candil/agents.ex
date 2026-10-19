defmodule Candil.Agents do
  @moduledoc """
  The door to the agents: find them by name, ask and wait for the answer.

  An agent is a process, and this module is how one process asks another
  something and gets an answer (`docs/04-modulos/05-agentes` §5.1, F5.5). Arrea
  did not have it — its `send_message/2` is a `cast`: `:ok` means «it was
  queued», never «it was processed» — and by **D-13** the RPC lives in Candil.

  ## Names

  An agent with a `:name` is registered in `Candil.Registry` under
  `{:agent, name}` — the tuple is the namespace, so an agent named «coder»
  does not collide with the engine of that alias. `via/1` builds the
  registration and `whereis/1` finds the pid.
  `Candil.Agents.SimpleReflex` registers when it is given a name;
  `Candil.Agents.ModelBasedReflex` always, because its name is its identity
  and its snapshot key. The registration follows the process: a restart
  re-registers, a stop unregisters, and a duplicate name does not fight —
  the second start is `{:error, {:already_started, pid}}`.

  ## The call

  `call/3` hands the message to the agent as the stimulus of the
  `{:evaluate, …}` it already speaks, and the answer is the agent's:
  `t:Candil.Agent.result/0` — `{:ok, answer, trace}` | `{:error, reason,
  trace}`.

  `:timeout` is the caller's patience; `:infinity` by default, and on purpose
  (F5.3): the agent answers always, because the deadline that kills a run
  lives inside it. Whoever knows their own budget says so, and running out of
  patience is answered like everything else — `{:error, :timeout, []}` — not
  as an exit. Measured before promising it: OTP discards the late reply, so
  the shorter deadline leaves no wreckage in the mailbox.

  ## When there is no agent

  A name with no process behind it is an answer, not an exit:
  `{:error, {:agent_not_up, name}, []}`, mirror of the
  `{:error, {:model_not_up, alias}, []}` of `run/3`. The same goes for an
  agent that dies while the caller waits — but only for normal deaths (the
  door catches what a supervisor can produce: `:normal`, `:shutdown`,
  `:killed`, `:noproc`, `:noconnection`); **a run that breaks is still a
  break**, and its exit reaches whoever called (F5.3).
  """

  alias Candil.Agent

  @registry Candil.Registry
  @key :agent

  @typedoc "An agent's name, as its `:name` gave it."
  @type name :: term()

  @typedoc "An agent: its name, or its pid."
  @type agent :: name() | pid()

  # Los exits que se contestan, y solo estos: los que produce una muerte
  # normal — `GenServer.call/3` envuelve la razon en `{razon, {GenServer,
  # :call, …}}`. Una caida con una razon RARA (un bug, un RuntimeError) se
  # propaga: tiene que verse en quien la sufre, y no quedarse aqui como un
  # `{:error, …}` que nadie sabe de donde salio. Es el mismo trato que
  # `Candil.Policy.Destination` le da a su cola.
  @call_exits [:normal, :shutdown, :killed, :noproc, :noconnection]

  @doc """
  The registered name of the agent — what `GenServer`'s `:name` option wants.

  With it the process is born registered, and a duplicate name does not start
  a second agent (`{:error, {:already_started, pid}}`). A restart re-registers
  by itself: the supervisor starts it again with the same options.
  """
  @spec via(name()) :: {:via, module(), {module(), {atom(), name()}}}
  def via(name), do: {:via, Registry, {@registry, {@key, name}}}

  @doc """
  The pid of the agent with that name, or `nil` when there is no one.
  """
  @spec whereis(name()) :: pid() | nil
  def whereis(name) do
    case Registry.lookup(@registry, {@key, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Hands `message` to the agent and waits for its answer.

  ## Arguments

    * `agent` — the agent's name, or its pid. By name it goes through the
      registry; by pid it calls straight, and a pid that is already dead is
      the same `{:error, {:agent_not_up, agent}, []}`: data, not an exit.

    * `message` — the stimulus. It travels as the `{:evaluate, message}` that
      `Candil.Agents.SimpleReflex` and `Candil.Agents.ModelBasedReflex`
      already answer; the RPC is a door, not a second protocol.

    * `opts` — `:timeout`, the caller's patience in ms; `:infinity` by
      default. The agent answers always — its own deadline lives inside — so
      the normal caller does not set it; whoever knows their budget does.

  ## Returns

  The agent's answer — `{:ok, answer, trace}` | `{:error, reason, trace}` —
  or `{:error, :timeout, []}` when the caller's patience ran out, or
  `{:error, {:agent_not_up, agent}, []}` when there is no agent to answer.
  """
  @spec call(agent(), term(), keyword()) :: Agent.result()
  def call(agent, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    case resolve(agent) do
      {:ok, pid} -> safe_call(agent, pid, {:evaluate, message, opts}, timeout)
      :error -> {:error, {:agent_not_up, agent}, []}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec resolve(agent()) :: {:ok, pid()} | :error
  defp resolve(pid) when is_pid(pid) do
    # Un pid ya muerto no se comprueba aqui: la carrera existe igual —puede
    # morirse entre la comprobacion y la llamada—, y `safe_call/4` la contesta
    # por el mismo camino que el `:noproc`.
    {:ok, pid}
  end

  defp resolve(name) do
    case whereis(name) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end

  @spec safe_call(agent(), pid(), term(), timeout()) :: Agent.result()
  defp safe_call(agent, pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in @call_exits ->
      {:error, {:agent_not_up, agent}, []}

    :exit, {:timeout, {GenServer, :call, _args}} ->
      {:error, :timeout, []}
  end
end
