defmodule Candil.RequestBuilder do
  @moduledoc """
  Shared request body builders for LLM providers.

  These functions normalise messages and build the JSON compatible request
  body maps for OpenAI-compatible, Anthropic, and Ollama APIs. Both the
  `Candil.Inference` (non-streaming) and `Candil.Stream` (SSE streaming)
  modules delegate here to avoid code duplication.

  ## Options

    * `:temperature` — sampling temperature (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences (OpenAI only, default: `[]`)
    * `:system` — system prompt string (prepended to messages)
    * `:stream` — enable SSE streaming (default: `false`)
    * `:tools` — list of tool definitions for function calling (default: `[]`)
    * `:tool_choice` — controls tool invocation (OpenAI only)

  ## Function calling

  Pass a list of tool definitions in `:tools`. Each tool is a map with
  `:name`, `:description`, and `:parameters` (JSON Schema). The provider
  will respond with a `tool_calls` field in the response when it wants
  to invoke a tool.

      tools = [
        %{
          name: "get_weather",
          description: "Get the current weather for a location",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["location"]
          }
        }
      ]

      Candil.chat(:gpt4, [%{role: "user", content: "Weather in Madrid?"}], tools: tools)

  The response will include a `tool_calls` key with the tool name and
  parsed arguments, which your code can then act on.

  All functions return a plain map ready for Jason.encode!/1.
  """

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @doc false
  @spec build_openai_body(binary(), [map()], keyword()) :: map()
  def build_openai_body(model_name, messages, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 512)
    stop = Keyword.get(opts, :stop, [])
    stream = Keyword.get(opts, :stream, false)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    tool_choice = Keyword.get(opts, :tool_choice)

    msgs = if system, do: [%{role: "system", content: system} | messages], else: messages

    body = %{
      model: model_name,
      messages: normalise_messages(msgs),
      temperature: temperature,
      max_tokens: max_tokens
    }

    body = if stream, do: Map.put(body, :stream, true), else: body

    body =
      if tools != [],
        do: Map.put(body, :tools, Enum.map(tools, &format_openai_tool/1)),
        else: body

    body = if tool_choice, do: Map.put(body, :tool_choice, tool_choice), else: body

    if stop != [], do: Map.put(body, :stop, stop), else: body
  end

  @doc false
  @spec build_anthropic_body(binary(), [map()], keyword()) :: map()
  def build_anthropic_body(model_name, messages, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 512)
    stream = Keyword.get(opts, :stream, false)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    {system_msgs, user_msgs} = Enum.split_with(messages, &(&1[:role] == "system"))

    system_text =
      case {system, system_msgs} do
        {s, _} when is_binary(s) -> s
        {nil, [msg | _]} -> msg[:content]
        _ -> nil
      end

    body = %{
      model: model_name,
      messages: normalise_messages(user_msgs),
      max_tokens: max_tokens,
      temperature: temperature
    }

    body = if stream, do: Map.put(body, :stream, true), else: body

    body =
      if tools != [],
        do: Map.put(body, :tools, Enum.map(tools, &format_anthropic_tool/1)),
        else: body

    if system_text, do: Map.put(body, :system, system_text), else: body
  end

  @doc false
  @spec build_ollama_chat_body(binary(), [map()], keyword()) :: map()
  def build_ollama_chat_body(model_name, messages, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    stream = Keyword.get(opts, :stream, false)
    system = Keyword.get(opts, :system)
    msgs = if system, do: [%{role: "system", content: system} | messages], else: messages

    %{
      model: model_name,
      messages: normalise_messages(msgs),
      options: %{temperature: temperature},
      stream: stream
    }
  end

  @doc false
  @spec normalise_messages([map()]) :: [map()]
  def normalise_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"] || "user"),
        "content" => to_string(msg[:content] || msg["content"] || "")
      }
    end)
  end

  defp format_openai_tool(%{name: n, description: d, parameters: p}) do
    %{
      "type" => "function",
      "function" => %{"name" => n, "description" => d, "parameters" => p}
    }
  end

  defp format_anthropic_tool(%{name: n, description: d, parameters: p}) do
    %{
      "name" => n,
      "description" => d,
      "input_schema" => p
    }
  end
end
