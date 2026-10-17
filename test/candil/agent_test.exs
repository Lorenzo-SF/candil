defmodule Candil.AgentTest do
  use ExUnit.Case, async: false

  alias Candil.{Cancellation, Model, Store, Tool}

  defmodule StubBackend do
    @behaviour Candil.Backend
    use GenServer

    @impl true
    def init(opts) do
      {:ok, %{responses: Keyword.get(opts, :responses, [])}}
    end

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def chat(_model, messages, _opts) do
      # Quien quiera ver QUE mensajes recibe el modelo se apunta aqui; el
      # observador es opcional y por defecto no hay ninguno.
      if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
        send(observer, {:chat_messages, messages})
      end

      case GenServer.call(__MODULE__, :take) do
        nil ->
          {:ok,
           %{
             content: "FINAL_ANSWER: all done",
             finish_reason: "stop",
             usage: %{input_tokens: 0, output_tokens: 0}
           }}

        response ->
          response
      end
    end

    @impl true
    def chat_stream(_, _, _), do: {:ok, []}

    @impl true
    def embed(_, _, _), do: {:ok, []}

    @impl true
    def models, do: []

    @impl true
    def handle_call(:take, _from, state) do
      case state.responses do
        [] ->
          {:reply, nil, state}

        [head | tail] ->
          {:reply, head, %{state | responses: tail}}
      end
    end

    @impl true
    def handle_call({:push, new_responses}, _from, state) do
      {:reply, :ok, %{state | responses: state.responses ++ new_responses}}
    end
  end

  defp push_responses(responses) do
    GenServer.call(StubBackend, {:push, responses})
  end

  defp final_response(text) do
    {:ok,
     %{
       content: "FINAL_ANSWER: #{text}",
       finish_reason: "stop",
       usage: %{input_tokens: 0, output_tokens: 0}
     }}
  end

  setup do
    # Candil.Tool and Candil.Cancellation are already started by the app.
    start_supervised({StubBackend, responses: []})
    Tool.reset()

    # Un alias de VERDAD. `Candil.Agent.run/3` comprueba que el modelo existe en
    # el catalogo antes de llamar al backend —un pin que no existe tiene que
    # ser un error ruidoso, aqui y no en el motor— asi que un test que usa
    # `model: "test"` tiene que registrar ese modelo.
    :ok =
      Store.register_model(%Model{
        alias: :test,
        type: :local,
        engine: :llama_cpp,
        model_dir: "/modelos",
        filename: "test.gguf",
        usage: [:chat]
      })

    on_exit(fn -> Store.deregister_model(:test) end)

    :persistent_term.put({StubBackend, :observer}, self())
    on_exit(fn -> :persistent_term.erase({StubBackend, :observer}) end)
    :ok
  end

  describe "run/3 with a config map" do
    test "returns the final answer when the model emits FINAL_ANSWER" do
      config = %{goal: "Be helpful", max_steps: 4, tool_schemas: []}

      assert {:ok, "all done", _trace} =
               Candil.Agent.run(config, "hi", backend: StubBackend, model: "test")
    end

    test "loops when the model emits a tool call" do
      # First response: tool call (sum 2 + 3). Second: final answer.
      Tool.define({"sum", "Add two numbers", %{}, fn %{"a" => a, "b" => b} -> {:ok, a + b} end})

      responses = [
        {:ok,
         %{
           content:
             ~s(<|tool_call|>\n{"name": "sum", "arguments": {"a": 2, "b": 3}}\n<|/tool_call|>),
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }},
        {:ok,
         %{
           content: "FINAL_ANSWER: 5",
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }}
      ]

      push_responses(responses)

      config = %{goal: "Math", max_steps: 4, tool_schemas: []}

      assert {:ok, "5", trace} =
               Candil.Agent.run(config, "What is 2 + 3?", backend: StubBackend, model: "test")

      # Trace contains the thought, the action, and the final step.
      assert Enum.any?(trace, &match?(%{kind: :thought}, &1))
      assert Enum.any?(trace, &match?(%{kind: :action}, &1))
    end

    test "respects max_steps" do
      # Loop forever with no FINAL_ANSWER — must stop after max_steps.
      Tool.define({"loop", "loops", %{}, fn _ -> {:ok, "again"} end})

      responses =
        Enum.map(1..5, fn _ ->
          {:ok,
           %{
             content: ~s(<|tool_call|>\n{"name": "loop", "arguments": {}}\n<|/tool_call|>),
             finish_reason: "stop",
             usage: %{input_tokens: 0, output_tokens: 0}
           }}
        end)

      push_responses(responses)

      config = %{goal: "Loop", max_steps: 3, tool_schemas: []}

      assert {:error, :max_steps_exhausted, trace} =
               Candil.Agent.run(config, "go", backend: StubBackend, model: "test")

      # Exactly max_steps tool calls.
      action_count = Enum.count(trace, &match?(%{kind: :action}, &1))
      assert action_count <= 3
    end
  end

  describe "el behaviour, paso a paso y sin proceso (F5.2)" do
    test "init_agent/1 sin backend dice por que no arranca" do
      assert {:stop, :no_backend} = Candil.Agent.init_agent([])
    end

    test "un paso entero se ejecuta sin arrancar ningun agente" do
      push_responses([final_response("hecho")])

      {:ok, state} =
        Candil.Agent.init_agent(config: %{goal: "g"}, backend: StubBackend, model: "test")

      assert {:ok, state, %{kind: :final, content: "hecho"}} =
               Candil.Agent.step(state, "hola", [])

      assert List.last(state.trace) == %{kind: :final, content: "hecho"}
    end

    test "el bucle de herramienta son pasos encadenados, no recursion" do
      Tool.define({"suma", "Suma", %{}, fn %{"a" => a, "b" => b} -> {:ok, a + b} end})

      push_responses([
        {:ok,
         %{
           content:
             ~s(<|tool_call|>\n{"name": "suma", "arguments": {"a": 1, "b": 2}}\n<|/tool_call|>),
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }},
        final_response("3")
      ])

      {:ok, state} =
        Candil.Agent.init_agent(config: %{goal: "g"}, backend: StubBackend, model: "test")

      assert {:ok, state, %{kind: :thought}} = Candil.Agent.step(state, "1+2", [])
      assert {:ok, state, %{kind: :final, content: "3"}} = Candil.Agent.step(state, nil, [])

      assert Enum.any?(state.trace, &match?(%{kind: :action}, &1))
    end
  end

  describe "la historia, y las sesiones de Candil.Context (F5.2)" do
    test "sin :session, la historia es de esta llamada" do
      push_responses([final_response("uno"), final_response("dos")])

      config = %{goal: "g", max_steps: 4, tool_schemas: []}

      assert {:ok, "uno", _} =
               Candil.Agent.run(config, "hola", backend: StubBackend, model: "test")

      assert_received {:chat_messages, primera}
      assert primera == [%{role: "system", content: "g"}, %{role: "user", content: "hola"}]

      assert {:ok, "dos", _} =
               Candil.Agent.run(config, "otra vez", backend: StubBackend, model: "test")

      assert_received {:chat_messages, segunda}
      refute Enum.any?(segunda, &(&1[:content] == "hola"))
    end

    test "con :session, la segunda llamada continua la conversacion" do
      sid = "f52-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Context.delete(:agent_f52_test, sid) end)

      push_responses([final_response("uno"), final_response("dos")])

      base = [backend: StubBackend, model: "test", consumer: :agent_f52_test, session: sid]
      config = %{goal: "g", max_steps: 4, tool_schemas: []}

      assert {:ok, "uno", _} = Candil.Agent.run(config, "hola", base)

      assert_received {:chat_messages, primera}
      assert primera == [%{role: "system", content: "g"}, %{role: "user", content: "hola"}]

      # La historia del run se quedo en la sesion: es la migracion de la
      # F5.2 — antes vivia en `Candil.Conversation`, en el proceso que
      # llamaba, y no la veia nadie mas.
      assert {:ok, session} = Candil.Context.get(:agent_f52_test, sid)
      assert session.messages == [%{role: "user", content: "hola"}]

      assert {:ok, "dos", _} = Candil.Agent.run(config, "otra vez", base)

      assert_received {:chat_messages, segunda}

      assert segunda == [
               %{role: "system", content: "g"},
               %{role: "user", content: "hola"},
               %{role: "user", content: "otra vez"}
             ]
    end
  end

  describe "snapshot/1 y restore/1: el último estado estable (F5.4)" do
    test "un estado fotografiado y restaurado es el mismo estado" do
      push_responses([final_response("uno")])

      {:ok, state} =
        Candil.Agent.init_agent(config: %{goal: "g"}, backend: StubBackend, model: "test")

      {:ok, state, _} = Candil.Agent.step(state, "hola", [])

      assert {:ok, restored} = Candil.Agent.restore(Candil.Agent.snapshot(state))
      assert restored == state
    end

    test "la referencia de cancelación no viaja: se queda fuera del snapshot" do
      ref = Cancellation.new_ref()

      {:ok, state} =
        Candil.Agent.init_agent(
          config: %{goal: "g"},
          backend: StubBackend,
          model: "test",
          cancel_ref: ref
        )

      snapshot = Candil.Agent.snapshot(state)

      refute Map.has_key?(snapshot, :cancel_ref)

      # Y al volver, la cancelación es cosa de un run muerto: nace en nil.
      assert {:ok, restored} = Candil.Agent.restore(snapshot)
      assert restored.cancel_ref == nil
    end

    test "y el snapshot es dato plano: cruza term_to_binary sin perder nada" do
      push_responses([final_response("hecho")])

      {:ok, state} =
        Candil.Agent.init_agent(config: %{goal: "g"}, backend: StubBackend, model: "test")

      {:ok, state, _} = Candil.Agent.step(state, "hola", [])

      snapshot = Candil.Agent.snapshot(state)

      assert :erlang.binary_to_term(:erlang.term_to_binary(snapshot)) == snapshot
    end

    test "restaurar y seguir da el mismo resultado que no haberse caído" do
      push_responses([final_response("uno"), final_response("dos"), final_response("dos")])

      {:ok, state} =
        Candil.Agent.init_agent(config: %{goal: "g"}, backend: StubBackend, model: "test")

      {:ok, state, _} = Candil.Agent.step(state, "uno", [])

      {:ok, restored} = Candil.Agent.restore(Candil.Agent.snapshot(state))
      assert restored == state

      # Dos caminos desde el mismo punto: el estado original y el revivido.
      assert {:ok, original, %{kind: :final, content: "dos"}} =
               Candil.Agent.step(state, "dos", [])

      assert {:ok, revivido, %{kind: :final, content: "dos"}} =
               Candil.Agent.step(restored, "dos", [])

      assert revivido == original
    end

    test "restore rechaza lo que no es un snapshot, y no deja entrar campos de más" do
      assert {:error, {:missing_key, :config}} = Candil.Agent.restore(%{})
      assert {:error, :not_a_snapshot} = Candil.Agent.restore(:no_es_un_mapa)

      {:ok, state} =
        Candil.Agent.init_agent(config: %{goal: "g"}, backend: StubBackend, model: "test")

      con_extra = Map.put(Candil.Agent.snapshot(state), :extra, 1)

      assert {:ok, restored} = Candil.Agent.restore(con_extra)
      refute Map.has_key?(restored, :extra)
    end
  end
end
