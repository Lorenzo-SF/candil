defmodule Candil.Agents.Supervisor do
  @moduledoc """
  The supervisor agents are started under.

  A worker is given its queue at start-up, so the supervisor that holds it can
  write down its whole list of children before any of them exist. An agent is
  given a goal and lives one step at a time, and how many agents there are
  tomorrow is not known at boot: that is a `DynamicSupervisor`, children
  started by name, one at a time.

  ## One for one

  `:one_for_one`, and it is a decision: agents do not share state, so an agent
  that crashes has nothing to restart together with its neighbours. The day two
  agents need to fall together is the day to reconsider, not before.

  ## Where it lives

  In the application tree since F5.3 (`docs/04-modulos/05-agentes`), the phase
  that brought the first real agent. Before that, it existed on its own: an
  empty supervisor in the tree would have been supervising nothing.

  ## What may be a child

  `start_agent/2` takes a module that exports `child_spec/1` and
  `start_link/1` — a `GenServer`, in practice. What describes an agent's work
  is `Candil.Agents.Behaviour`; the process around that work is OTP's.
  """

  use DynamicSupervisor

  @typedoc "An agent, as `DynamicSupervisor.which_children/1` reports it."
  @type agent ::
          {:undefined, pid() | :restarting, :worker | :supervisor, [module()] | :dynamic}

  @doc "Starts the supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts `agent` under the supervisor.

  Returns what `DynamicSupervisor.start_child/2` returns — `{:ok, pid}`, or
  `{:error, {:already_started, pid}}` when the started process is registered
  and already exists.
  """
  @spec start_agent(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(agent, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {agent, opts})
  end

  @doc "Stops the agent with that pid."
  @spec stop_agent(pid()) :: :ok | {:error, :not_found}
  def stop_agent(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  The live agents, as `DynamicSupervisor.which_children/1` reports them.

  The id is `:undefined`: dynamic children do not have one.
  """
  @spec list_agents() :: [agent()]
  def list_agents do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
