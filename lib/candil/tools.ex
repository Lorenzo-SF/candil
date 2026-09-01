defmodule Candil.Tools do
  @moduledoc """
  Tool calling for LLM responses.

  Most modern LLMs (OpenAI, Anthropic, llama.cpp with `--jinja` /
  function-calling grammar) support tool calling: the model returns
  structured JSON instead of (or alongside) free-form text.

  This module:

    1. Serialises a list of `Candil.Tool.t/0` schemas into the prompt
       (or the API's `tools` parameter) — `schemas_to_prompt/1`.
    2. Parses the model's response into a list of `%ToolCall{}` structs
       — `parse_tool_calls/1`.

  ## OpenAI-compatible wire format

      %{
        "type" => "function",
        "function" => %{
          "name" => "get_weather",
          "description" => "Get the current weather",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string"}
            },
            "required" => ["city"]
          }
        }
      }

  ## Local (llama.cpp) prompt format

  A `<|tool_call|>` style marker followed by JSON. The parser is
  forgiving: leading/trailing whitespace and stray markdown fences
  are tolerated.
  """

  alias Candil.Tool

  @type wire_schema :: map()

  @type tool_call :: %{name: String.t(), args: map()}

  @doc """
  Serialise a list of `Candil.Tool.t/0` into OpenAI-compatible wire
  schemas suitable for `body["tools"]`.

  Each entry is `%{"type" => "function", "function" => %{...}}`.
  """
  @spec schemas_to_prompt([Tool.t()]) :: [wire_schema()]
  def schemas_to_prompt(tools) when is_list(tools) do
    Enum.map(tools, &to_wire_schema/1)
  end

  defp to_wire_schema(%Tool{name: name, description: desc, schema: schema}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => schema
      }
    }
  end

  @doc """
  Parse a model's response into a list of `tool_call/0` maps.

  Accepts either:

    * A string with `<|tool_call|>` (or `<tool_call>`) markers followed
      by JSON, separated by whitespace and possibly surrounded by
      markdown fences.
    * An OpenAI-style response map with a `tool_calls` array.

  Returns `{:ok, [tool_call()]}` on success or
  `{:error, %Candil.Error{}}` if a JSON block fails to parse.
  """
  @spec parse_tool_calls(String.t() | map()) :: {:ok, [tool_call()]} | {:error, term()}
  def parse_tool_calls(%{} = response) do
    cond do
      is_list(response["tool_calls"]) ->
        parse_openai_tool_calls(response["tool_calls"])

      is_binary(response["content"]) ->
        parse_tool_calls(response["content"])

      true ->
        {:error, %Candil.Error{reason: :invalid_request, context: %{message: "no tool_calls in response"}}}
    end
  end

  def parse_tool_calls(text) when is_binary(text) do
    extract_blocks(text)
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_tool_block(block) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _} = err -> err
    end
  end

  # Decode a JSON block that represents a single tool call.
  # Accepts either:
  #   * `{"name": "fn", "arguments": {...}}`  (modern llama.cpp format)
  #   * `{"name": "fn", "args": {...}}`        (some local templates)
  # Returns the internal `%{name: ..., args: ...}` shape.
  @spec decode_tool_block(String.t()) :: {:ok, tool_call()} | {:error, term()}
  defp decode_tool_block(block) do
    with {:ok, %{} = map} <- decode_json(block),
         {:ok, name} <- fetch_name(map),
         {:ok, args} <- fetch_args(map) do
      {:ok, %{name: name, args: args}}
    end
  end

  defp fetch_name(map) do
    cond do
      is_binary(map["name"]) -> {:ok, map["name"]}
      is_binary(map[:name]) -> {:ok, map[:name]}
      true -> {:error, %Candil.Error{reason: :invalid_request, context: %{message: "missing name"}}}
    end
  end

  defp fetch_args(map) do
    cond do
      is_map(map["arguments"]) -> {:ok, map["arguments"]}
      is_map(map[:arguments]) -> {:ok, map[:arguments]}
      is_map(map["args"]) -> {:ok, map["args"]}
      is_map(map[:args]) -> {:ok, map[:args]}
      true -> {:ok, %{}}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @doc false
  @spec parse_openai_tool_calls([map()]) :: {:ok, [tool_call()]} | {:error, term()}
  defp parse_openai_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      fn_name = get_in(call, ["function", "name"]) || call["name"]
      fn_args_json = get_in(call, ["function", "arguments"]) || call["arguments"]

      cond do
        is_nil(fn_name) ->
          {:halt, {:error, %Candil.Error{reason: :invalid_request, context: %{message: "missing name"}}}}

        is_nil(fn_args_json) ->
          {:halt, {:error, %Candil.Error{reason: :invalid_request, context: %{message: "missing args"}}}}

        true ->
          case decode_json(fn_args_json) do
            {:ok, args} -> {:cont, {:ok, [%{name: fn_name, args: args} | acc]}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _} = err -> err
    end
  end

  # Extract JSON-looking blocks from a free-form response. We look for
  # either `<|tool_call|> ... <|/tool_call|>` markers or bare JSON
  # objects that contain a `name` + `arguments` shape. Markdown
  # fences are stripped BEFORE the JSON check so the filter recognises
  # ```json\n{...}\n``` blocks.
  @spec extract_blocks(String.t()) :: [String.t()]
  defp extract_blocks(text) do
    text
    |> String.split(~r/<\|?(\/?tool_call)\|?>/)
    |> Enum.map(&strip_code_fence/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&json_object?/1)
  end

  defp strip_code_fence(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  defp json_object?(text) do
    String.starts_with?(text, "{") and String.ends_with?(text, "}")
  end

  @spec decode_json(String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _} -> {:error, %Candil.Error{reason: :invalid_request, context: %{message: "tool call must be JSON object"}}}
      {:error, %Jason.DecodeError{} = err} -> {:error, %Candil.Error{reason: :invalid_request, context: %{message: Exception.message(err)}}}
    end
  end

  defp decode_json(_), do: {:error, %Candil.Error{reason: :invalid_request, context: %{message: "non-string json"}}}
end