defmodule Candil.InferenceTest do
  use ExUnit.Case, async: true

  alias Candil.{Error, Inference}

  # Note: The parsing functions in Inference are private.
  # Full HTTP mocking of Req.post/Req.get requires code modifications.
  # These tests focus on error handling when engine is not running.

  describe "error handling" do
    test "chat_local returns error when model not found" do
      result = Inference.chat_local(:nonexistent_model, [%{role: "user", content: "Hello"}], [])

      assert {:error,
              %Error{reason: :model_not_found, context: %{model_alias: :nonexistent_model}}} =
               result
    end

    test "embed_local returns error when model not found" do
      result = Inference.embed_local(:nonexistent_model, ["Hello"], [])

      assert {:error,
              %Error{reason: :model_not_found, context: %{model_alias: :nonexistent_model}}} =
               result
    end
  end

  describe "response parsing" do
    # These would test the private parsing functions if they were public
    # For now, we test through the public API
  end
end
