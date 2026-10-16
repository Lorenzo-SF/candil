defmodule Candil.Agent.ContractTest do
  @moduledoc """
  El contrato de `Candil.Agent`, que es lo que un tercero lee antes de escribir
  su agente. Si el contrato miente, el tercero escribe contra la mentira.

  Los tres primeros son **de contrato**: leen la declaración que lee un humano y
  fallan si vuelve a mentir. Es el mismo truco que ya usa Arrea con
  `send_message/2`, donde el `@spec` decia `:ok` y dialyzer confirmaba la
  mentira.

  Escritos antes del código. Un test escrito despues del codigo es una
  descripcion de lo que hizo el codigo.
  """

  use ExUnit.Case, async: false

  alias Candil.Agent

  defmodule StubBackend do
    @moduledoc false
    # Un backend que no hace nada: para los tests de contrato solo hace falta
    # que exista y pueda ser llamado, no que pense.
    def chat(_model, _messages, _opts), do: {:ok, %{content: "", tool_calls: nil}}
  end

  describe "el contrato" do
    test "result/0 declara la forma de error que finalize/1 devuelve de verdad" do
      fuente = File.read!("lib/candil/agent.ex")

      assert fuente =~ "@type result :: {:ok, String.t(), trace()} | {:error, term(), trace()}"
    end
  end

  describe "lo que se prometio y no habia" do
    test "run/3 sin :backend devuelve un error en vez de llamar a nil.chat/3" do
      config = %{goal: "g", max_steps: 1, tool_schemas: []}

      assert {:error, :no_backend, []} = Agent.run(config, "hola")
    end

    test "un alias que no esta en el catalogo es un error ruidoso" do
      config = %{goal: "g", max_steps: 1, tool_schemas: []}

      # El motivo va anidado porque la tercera posicion de `result()` es la
      # traza, y "inventado" ahi no seria una traza.
      assert {:error, {:model_not_up, "inventado"}, []} =
               Agent.run(config, "hola",
                 backend: StubBackend,
                 model: "inventado"
               )
    end
  end

  describe "el `use` documentado" do
    defmodule WeatherAgent do
      @moduledoc false
      use Candil.Agent,
        name: "weather",
        goal: "Responder preguntas meteorologicas",
        tools: [],
        max_steps: 2
    end

    test "declara lo que promete" do
      assert %{name: "weather", goal: "Responder preguntas meteorologicas", max_steps: 2} =
               WeatherAgent.__agent_config__()
    end

    test "y el modulo que genera, corre por el mismo camino" do
      # El `use` funciona —eso ya era verde— pero lo que no existia era que
      # `run/2` estuviera comprobado. Sin backend, este modulo ahora devuelve
      # `{:error, :no_backend}` en vez de morir.
      assert {:error, :no_backend, []} = WeatherAgent.run("hola")
    end
  end

  describe "el behaviour, declarado y no solo documentado (F5.2)" do
    test "Candil.Agent implementa el behaviour de los agentes" do
      fuente = File.read!("lib/candil/agent.ex")

      assert fuente =~ "@behaviour Candil.Agents.Behaviour"
    end

    test "y los callbacks obligatorios del behaviour existen todos" do
      {:module, _} = Code.ensure_loaded(Candil.Agent)

      optional = Candil.Agents.Behaviour.behaviour_info(:optional_callbacks)

      for {fun, arity} <- Candil.Agents.Behaviour.behaviour_info(:callbacks) -- optional do
        assert function_exported?(Candil.Agent, fun, arity),
               "Candil.Agent no exporta #{fun}/#{arity}, y el behaviour lo exige"
      end
    end

    test "run/3 ya no promete la opcion que nunca existio" do
      {:module, _} = Code.ensure_loaded(Candil.Agent)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Candil.Agent)

      {{:function, :run, 3}, _, _, %{"en" => doc}, _} =
        List.keyfind(docs, {:function, :run, 3}, 0)

      refute doc =~ ":conversation"
      assert doc =~ ":session"
    end
  end
end
