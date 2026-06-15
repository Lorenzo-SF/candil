defmodule Candil.LlmTest do
  use ExUnit.Case, async: true

  alias Candil.{Error, Llm}

  describe "download_engine/1" do
    test "returns :ok when use_precompiled is false" do
      engine = %Candil.Engine{alias: :test, use_precompiled: false}
      assert Llm.download_engine(engine) == :ok
    end
  end

  describe "download_model/1" do
    test "returns ok for remote models" do
      model = %Candil.Model{
        alias: :gpt4o,
        type: :remote,
        name: "gpt-4o",
        provider: :openai
      }

      assert Llm.download_model(model) == {:ok, "gpt4o"}
    end
  end

  describe "stop_engine/1" do
    test "delegates to Engine.stop and returns error when not running" do
      # When engine is not running, Engine.stop returns {:error, :not_running}
      assert Llm.stop_engine(:nonexistent) == {:error, :not_running}
    end
  end

  describe "engine_healthy?/1" do
    test "delegates to Engine.healthy? and returns false when not running" do
      # When engine is not running, Engine.healthy? returns false
      refute Llm.engine_healthy?(:nonexistent)
    end
  end

  describe "chat/3 - local model" do
    test "returns error when model not found" do
      result = Llm.chat(:nonexistent_model, [%{role: "user", content: "Hello"}], [])

      assert {:error,
              %Error{reason: :model_not_found, context: %{model_alias: :nonexistent_model}}} =
               result
    end
  end

  describe "embed/2 - local model" do
    test "returns error when model not found" do
      result = Llm.embed(:nonexistent_model, ["Hello"], [])

      assert {:error,
              %Error{reason: :model_not_found, context: %{model_alias: :nonexistent_model}}} =
               result
    end
  end
end
