defmodule Candil.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias Candil.RequestBuilder

  describe "build_openai_body/3" do
    test "basic body" do
      body = RequestBuilder.build_openai_body("gpt-4o", [%{role: "user", content: "hi"}], [])
      assert body.model == "gpt-4o"
      assert is_list(body.messages)
      assert body.temperature == 0.7
      assert body.max_tokens == 512
    end

    test "with system prompt" do
      body =
        RequestBuilder.build_openai_body(
          "gpt-4o",
          [%{role: "user", content: "hi"}],
          system: "You are helpful"
        )

      assert hd(body.messages) == %{"role" => "system", "content" => "You are helpful"}
    end

    test "with tools (function calling)" do
      tools = [
        %{
          name: "get_weather",
          description: "Get the current weather",
          parameters: %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          }
        }
      ]

      body =
        RequestBuilder.build_openai_body(
          "gpt-4o",
          [%{role: "user", content: "weather in Madrid?"}],
          tools: tools
        )

      assert [tool] = body.tools
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "get_weather"
    end

    test "with tool_choice" do
      body =
        RequestBuilder.build_openai_body(
          "gpt-4o",
          [%{role: "user", content: "hi"}],
          tools: [%{name: "x", description: "x", parameters: %{}}],
          tool_choice: "auto"
        )

      assert body.tool_choice == "auto"
    end

    test "with stream enabled" do
      body =
        RequestBuilder.build_openai_body("gpt-4o", [%{role: "user", content: "hi"}], stream: true)

      assert body.stream == true
    end
  end

  describe "build_anthropic_body/3" do
    test "with tools uses input_schema" do
      tools = [
        %{
          name: "get_weather",
          description: "Get the weather",
          parameters: %{"type" => "object"}
        }
      ]

      body =
        RequestBuilder.build_anthropic_body("claude-3-5-sonnet", [], tools: tools)

      assert [tool] = body.tools
      assert tool["name"] == "get_weather"
      assert tool["input_schema"] == %{"type" => "object"}
    end
  end
end
