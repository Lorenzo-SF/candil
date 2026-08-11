defmodule Candil.ToolTest do
  use ExUnit.Case, async: false

  alias Candil.Tool

  setup do
    start_supervised(Tool)
    Tool.reset()
    :ok
  end

  describe "define/1 + call/2 + list/0" do
    test "round-trips a registered tool" do
      tool = %Tool{
        name: "add",
        description: "Add two numbers",
        schema: %{"type" => "object"},
        function: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
      }

      assert Tool.define(tool) == :ok
      assert [%Tool{name: "add"}] = Tool.list()
      assert {:ok, 5} = Tool.call("add", %{"a" => 2, "b" => 3})
    end

    test "call/2 returns :not_found for unknown tool" do
      assert {:error, %Candil.Error{reason: :not_found}} = Tool.call("nope", %{})
    end

    test "function returning {:error, reason} propagates through" do
      tool = %Tool{
        name: "always_fail",
        description: "Fails always",
        schema: %{},
        function: fn _ -> {:error, :bad_day} end
      }

      Tool.define(tool)
      assert {:error, :bad_day} = Tool.call("always_fail", %{})
    end
  end

  describe "validate_args/2" do
    test "ok when all required keys are present" do
      tool = %Tool{
        name: "t",
        description: "",
        schema: %{"required" => ["a", "b"]},
        function: fn _ -> :ok end
      }

      assert Tool.validate_args(tool, %{"a" => 1, "b" => 2}) == :ok
    end

    test "error when required keys are missing" do
      tool = %Tool{
        name: "t",
        description: "",
        schema: %{"required" => ["a", "b"]},
        function: fn _ -> :ok end
      }

      assert {:error, %Candil.Error{reason: :invalid_request}} =
               Tool.validate_args(tool, %{"a" => 1})
    end

    test "ok when no required keys declared" do
      tool = %Tool{name: "t", description: "", schema: %{}, function: fn _ -> :ok end}
      assert Tool.validate_args(tool, %{}) == :ok
    end
  end

  describe "schemas_to_prompt/1" do
    test "produces OpenAI-compatible wire format" do
      tools = [
        %Candil.Tool{
          name: "get_weather",
          description: "Get the current weather",
          schema: %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}, "required" => ["city"]},
          function: fn _ -> :ok end
        }
      ]

      assert [schema] = Candil.Tools.schemas_to_prompt(tools)
      assert schema["type"] == "function"
      assert schema["function"]["name"] == "get_weather"
      assert schema["function"]["description"] == "Get the current weather"
      assert schema["function"]["parameters"]["required"] == ["city"]
    end
  end
end