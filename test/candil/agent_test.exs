defmodule Candil.AgentTest do
  use ExUnit.Case, async: false

  alias Candil.{Cancellation, Tool}

  defmodule StubBackend do
    @behaviour Candil.Backend
    use GenServer

    @impl true
    def init(opts) do
      {:ok, %{responses: Keyword.get(opts, :responses, [])}}
    end

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def chat(_model, _messages, _opts) do
      case GenServer.call(__MODULE__, :take) do
        nil ->
          {:ok, %{content: "FINAL_ANSWER: all done", finish_reason: "stop", usage: %{input_tokens: 0, output_tokens: 0}}}

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

  setup do
    # Candil.Tool and Candil.Cancellation are already started by the app.
    start_supervised({StubBackend, responses: []})
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
           content: ~s(<|tool_call|>\n{"name": "sum", "arguments": {"a": 2, "b": 3}}\n<|/tool_call|>),
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
end