defmodule Candil.Agents.BehaviourTest do
  @moduledoc """
  El contrato de `Candil.Agents.Behaviour`, que es lo que un tercero lee antes
  de escribir su agente.

  ## Por qué este test existe

  El behaviour nació en la F5.1 (`docs/04-modulos/05-agentes` §5.2). Lo que se
  prueba aquí no es que llame a nadie —todavía no hay proceso que lo use—, sino
  que son los cinco callbacks que se decidieron, que tres son opcionales, y que
  un agente de tipo 1 se escribe con los dos que quedan: se puede razonar sin
  encender nada.
  """

  use ExUnit.Case, async: true

  # El agente de tipo 1: estímulo → respuesta, sin memoria. Implementa SOLO
  # los dos callbacks obligatorios — `describe/0`, `snapshot/1` y `restore/1`
  # no son suyos.
  defmodule ReflexAgent do
    @moduledoc false
    @behaviour Candil.Agents.Behaviour

    @impl true
    def init_agent(opts), do: {:ok, %{goal: opts[:goal]}}

    @impl true
    def step(state, input, _opts), do: {:ok, state, "eco: #{input}"}
  end

  describe "el contrato" do
    test "son cinco callbacks, y tres de ellos opcionales" do
      callbacks = Candil.Agents.Behaviour.behaviour_info(:callbacks)
      optional = Candil.Agents.Behaviour.behaviour_info(:optional_callbacks)

      assert Enum.sort(callbacks) ==
               Enum.sort(init_agent: 1, step: 3, describe: 0, snapshot: 1, restore: 1)

      assert Enum.sort(optional) == Enum.sort(describe: 0, snapshot: 1, restore: 1)
    end

    test "la forma de cada callback está escrita, y no cambia sola" do
      fuente = File.read!("lib/candil/agents/behaviour.ex")

      assert fuente =~ "{:ok, agent_state} | {:stop, term()}"
      assert fuente =~ "{:ok, agent_state, term()} | {:error, term(), agent_state}"
    end
  end

  describe "un agente de tipo 1" do
    test "se escribe con dos callbacks: init_agent/1 y step/3" do
      assert {:ok, %{goal: "responder"}} = ReflexAgent.init_agent(goal: "responder")
    end

    test "y su paso se prueba sin proceso — la promesa de §5.2" do
      {:ok, estado} = ReflexAgent.init_agent(goal: "responder")

      assert {:ok, ^estado, "eco: hola"} = ReflexAgent.step(estado, "hola", [])
    end
  end
end
