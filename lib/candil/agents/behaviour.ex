defmodule Candil.Agents.Behaviour do
  @moduledoc """
  Behaviour for a long-lived process whose next unit of work is not known yet.

  A worker is given a queue at start-up. An agent is given a goal and decides
  one step at a time, because what the second step is depends on what the model
  answered to the first.

  ## The step is a function, not a message

  `step/3` is pure: same state, same input, same result. It is the callback
  that replaces the queue, and it is a function on purpose — an agent can be
  reasoned about, and tested, without starting a process. The process that
  owns the state (F5.3) will call this same function, one step at a time.

  ## Where it lives, and what an «agent» is

  Born in Candil, not in Arrea: **D-13** (`docs/08-decisiones/README.md`) — to
  Arrea goes what Arrea needs for itself or what a second consumer asks for,
  and this contract had one consumer. And «agent» means this and nobody else:
  **D-14** — the participants of the mesa camilla (fase 9) are voices.

  The contract is the one proposed in `docs/04-modulos/05-agentes` §5.2 and
  confirmed by F5.1, name included.
  """

  @typedoc """
  The state a step threads through: tools, memory, goals. Opaque — nothing in
  this behaviour looks inside it.
  """
  @type agent_state :: term()

  @typedoc "What arrives: the goal at `init_agent/1`, the stimulus at every step."
  @type input :: term()

  @doc """
  Builds the initial state. A process that cannot start must say why.
  """
  @callback init_agent(keyword()) :: {:ok, agent_state} | {:stop, term()}

  @doc """
  One unit of work. Pure: same state + same input, same result.

  This is the callback that replaces the queue. It is a function, not a
  message, so an agent can be reasoned about — and tested — without starting a
  process.
  """
  @callback step(agent_state, input, keyword()) ::
              {:ok, agent_state, term()} | {:error, term(), agent_state}

  @doc """
  Static metadata: name, goal, kind. Arity 0 on purpose: a supervisor holding
  the name of a dead agent has no state to give it.
  """
  @callback describe() :: map()

  @doc "The last state worth restarting from."
  @callback snapshot(agent_state) :: map()

  @doc "Go back to a snapshot. Only reachable when `snapshot/1` is implemented."
  @callback restore(map()) :: {:ok, agent_state} | {:error, term()}

  @optional_callbacks snapshot: 1, restore: 1, describe: 0
end
