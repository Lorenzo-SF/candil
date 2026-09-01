defmodule Candil.Agent do
  @moduledoc """
  A minimal ReAct-style agent that uses tools.

  ReAct (Reason + Act) alternates between:
    1. Reasoning — the model decides what to do next.
    2. Acting — invoke a tool if needed.
    3. Observing — feed the tool's result back as a new message.

  The loop continues until either:
    * The model emits a final answer (no tool calls).
    * `max_steps` is reached (default 8).

  ## Conversation history

  The agent maintains its own conversation; pass an optional
  `Candil.Conversation` to start with a system prompt.

  ## Stop words

  If the model's response contains one of the configured stop words
  (default `"FINAL_ANSWER"`), the loop terminates.

  ## Example

      defmodule MyApp.WeatherAgent do
        use Candil.Agent,
          name: "weather",
          goal: "Answer weather questions",
          tools: [Candil.MyTools.get_weather],
          max_steps: 6
      end

      MyApp.WeatherAgent.run("What's the weather in Madrid?")
  """

  alias Candil.{Cancellation, Conversation, Telemetry, Tool, Tools}

  @type step :: %{kind: :thought | :action | :observation | :final, content: term()}
  @type trace :: [step()]
  @type result :: {:ok, String.t(), trace()} | {:error, term()}

  @default_max_steps 8

  @doc """
  Run the agent synchronously. Returns `{:ok, final_answer, trace}` on
  success or `{:error, term()}` on failure.

  ## Options

    * `:backend` — `Candil.Backend` module to use.
    * `:model` — model id (string or atom).
    * `:max_steps` — max loop iterations (default 8).
    * `:cancel_ref` — cancellation ref from `Candil.Cancellation.new_ref/0`.
    * `:conversation` — pre-seeded conversation.
  """
  @spec run(module() | map(), String.t() | nil, keyword()) :: result()
  def run(agent, input, opts \\ [])

  def run(%{} = config, input, opts) do
    do_run(config, input, opts)
  end

  def run(agent_module, input, opts) when is_atom(agent_module) do
    config = agent_module.__agent_config__()
    do_run(config, input, opts)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec do_run(map(), String.t() | nil, keyword()) :: result()
  defp do_run(config, input, opts) do
    backend = resolve_backend(opts)
    model = resolve_model(opts, config)
    max_steps = Keyword.get(opts, :max_steps, config[:max_steps] || @default_max_steps)
    cancel_ref = Keyword.get(opts, :cancel_ref)

    conversation = Conversation.new(model: model, system: config[:goal])
    conversation = if input, do: Conversation.add_message(conversation, "user", input), else: conversation

    trace = loop(conversation, config, backend, model, max_steps, cancel_ref, [])
    finalize(trace)
  end

  @spec resolve_backend(keyword()) :: module() | nil
  defp resolve_backend(opts) do
    case opts[:backend] do
      nil -> nil
      mod -> mod
    end
  end

  @spec resolve_model(keyword(), map()) :: String.t() | atom()
  defp resolve_model(opts, config) do
    Keyword.get(opts, :model) || config[:model] || "default"
  end

  @spec loop(Conversation.t(), map(), module() | nil, String.t() | atom(), non_neg_integer(), reference() | nil, trace()) ::
          trace()
  defp loop(_conv, _cfg, _backend, _model, 0, _ref, trace), do: trace ++ [%{kind: :final, content: :max_steps_exhausted}]

  defp loop(conv, cfg, backend, model, steps_left, cancel_ref, trace) do
    if cancel_ref && Cancellation.cancelled?(cancel_ref) do
      Telemetry.emit_cancellation(cancel_ref_to_id(cancel_ref), :cancelled)
      trace ++ [%{kind: :final, content: :cancelled}]
    else
      messages = Conversation.messages(conv)
      prompt_schemas = Tool.list() |> schemas_for(cfg)

      case backend.chat(model, messages, tools: prompt_schemas) do
        {:ok, %{content: content}} ->
          cond do
            stop_word_reached?(content, cfg) ->
              trace ++ [%{kind: :final, content: extract_final(content, cfg)}]

            true ->
              case Tools.parse_tool_calls(content) do
                {:ok, calls} ->
                  trace = trace ++ [%{kind: :thought, content: content}]
                  {observations, new_conv} = invoke_tools(calls, conv)

                  trace =
                    trace ++
                      Enum.map(observations, fn {name, result} ->
                        %{kind: :action, content: %{name: name, result: result}}
                      end)

                  loop(new_conv, cfg, backend, model, steps_left - 1, cancel_ref, trace)

                {:error, _} ->
                  # No tool calls and no stop word — treat the content
                  # as the final answer.
                  trace ++ [%{kind: :final, content: content}]
              end
          end

        {:error, _} = err ->
          trace ++ [%{kind: :final, content: {:error, err}}]
      end
    end
  end

  @spec invoke_tools([%{name: String.t(), args: map()}], Conversation.t()) ::
          {[{String.t(), {:ok, term()} | {:error, term()}}], Conversation.t()}
  defp invoke_tools(calls, conv) do
    Enum.reduce(calls, {[], conv}, fn %{name: name, args: args}, {acc, c} ->
      result = Tool.call(name, args)
      conv = Conversation.add_message(c, "user", observation_message(name, result))
      {[{name, result} | acc], conv}
    end)
    |> case do
      {acc, conv} -> {Enum.reverse(acc), conv}
    end
  end

  @spec observation_message(String.t(), {:ok, term()} | {:error, term()}) :: String.t()
  defp observation_message(name, result) do
    "Observation (#{name}): #{inspect(result)}"
  end

  @spec schemas_for([Tool.t()], map()) :: [map()]
  defp schemas_for(tools_in_registry, cfg) do
    cfg_schemas = cfg[:tool_schemas] || []
    reg_schemas = Tools.schemas_to_prompt(tools_in_registry)
    cfg_schemas ++ reg_schemas
  end

  @spec stop_word_reached?(String.t(), map()) :: boolean()
  defp stop_word_reached?(content, cfg) do
    stop = cfg[:stop_word] || "FINAL_ANSWER"
    String.contains?(content, stop)
  end

  @spec extract_final(String.t(), map()) :: String.t()
  defp extract_final(content, cfg) do
    stop = cfg[:stop_word] || "FINAL_ANSWER"

    # Take the text AFTER the stop word (ReAct convention:
    # "FINAL_ANSWER: <answer>"), fall back to the whole content.
    case String.split(content, stop) do
      [_] -> String.trim(content)
      [_prefix, rest | _] -> rest |> String.trim() |> String.trim_leading(":") |> String.trim()
    end
  end

  @spec cancel_ref_to_id(reference()) :: String.t()
  defp cancel_ref_to_id(ref), do: inspect(ref)

  @spec finalize(trace()) :: result()
  defp finalize(trace) do
    case List.last(trace) do
      %{kind: :final, content: content} when is_binary(content) ->
        {:ok, content, Enum.reject(trace, &match?(%{kind: :final}, &1))}

      %{kind: :final, content: other} ->
        {:error, other, Enum.reject(trace, &match?(%{kind: :final}, &1))}

      _ ->
        {:ok, "", trace}
    end
  end

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    goal = Keyword.get(opts, :goal, "")
    tools = Keyword.get(opts, :tools, [])
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    tool_schemas = Tools.schemas_to_prompt(tools)

    quote do
      def __agent_config__ do
        %{
          name: unquote(name),
          goal: unquote(goal),
          max_steps: unquote(max_steps),
          tool_schemas: unquote(Macro.escape(tool_schemas))
        }
      end

      def run(input, opts \\ []) do
        Candil.Agent.run(__MODULE__, input, opts)
      end
    end
  end
end