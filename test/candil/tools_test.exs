defmodule Candil.ToolsTest do
  use ExUnit.Case, async: true

  alias Candil.{Error, Tools}

  describe "parse_tool_calls/1 — OpenAI format" do
    test "parses a single tool call" do
      response = %{
        "tool_calls" => [
          %{
            "function" => %{
              "name" => "get_weather",
              "arguments" => ~s({"city": "Madrid"})
            }
          }
        ]
      }

      assert {:ok, [%{name: "get_weather", args: %{"city" => "Madrid"}}]} =
               Tools.parse_tool_calls(response)
    end

    test "parses multiple tool calls" do
      response = %{
        "tool_calls" => [
          %{"function" => %{"name" => "f1", "arguments" => "{}"}},
          %{"function" => %{"name" => "f2", "arguments" => ~s({"x": 1})}}
        ]
      }

      assert {:ok, [%{name: "f1", args: %{}}, %{name: "f2", args: %{"x" => 1}}]} =
               Tools.parse_tool_calls(response)
    end

    test "returns :invalid_request when name is missing" do
      response = %{"tool_calls" => [%{"function" => %{"arguments" => "{}"}}]}
      assert {:error, %Error{reason: :invalid_request}} = Tools.parse_tool_calls(response)
    end

    test "returns :invalid_request when args is malformed JSON" do
      response = %{"tool_calls" => [%{"function" => %{"name" => "f", "arguments" => "not json"}}]}
      assert {:error, %Error{reason: :invalid_request}} = Tools.parse_tool_calls(response)
    end
  end

  describe "parse_tool_calls/1 — local (string) format" do
    test "parses a `<|tool_call|>` block" do
      text = ~s(<|tool_call|>\n{"name": "get_weather", "arguments": {"city": "Madrid"}}\n<|/tool_call|>)

      assert {:ok, [%{name: "get_weather", args: %{"city" => "Madrid"}}]} =
               Tools.parse_tool_calls(text)
    end

    test "tolerates markdown code fences" do
      text = "```json\n{\"name\": \"f\", \"arguments\": {}}\n```"
      assert {:ok, [%{name: "f", args: %{}}] = _} = Tools.parse_tool_calls(text)
    end

    test "returns :invalid_request when JSON is malformed" do
      text = ~s(<|tool_call|>\n{not json}\n<|/tool_call|>)
      assert {:error, %Error{reason: :invalid_request}} = Tools.parse_tool_calls(text)
    end
  end
end