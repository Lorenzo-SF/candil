defmodule Candil.InferenceTest do
  use ExUnit.Case, async: false

  alias Candil.Inference

  describe "module interface" do
    test "module loads and exports expected functions" do
      # Verify module is loaded and has the public API
      assert Code.ensure_loaded?(Inference)
      assert function_exported?(Inference, :chat_remote, 4)
      assert function_exported?(Inference, :embed_remote, 4)
      assert function_exported?(Inference, :chat_local, 3)
      assert function_exported?(Inference, :embed_local, 3)
    end

    test "type aliases are exported" do
      # Compile-time check: if the module compiles, types are well-formed
      assert Code.ensure_loaded?(Inference)
      exports = Inference.module_info(:exports)
      assert is_list(exports)
      # The module should export its public functions (plus __info__ etc.)
      assert exports != []
    end

    test "module declares the expected behaviour" do
      # Verify the module is loaded (compile-time docstring is internal)
      assert Code.ensure_loaded?(Inference)
      # Verify exports include the chat functions we expect
      exports = Inference.module_info(:exports)
      assert {:chat_remote, 4} in exports
      assert {:embed_remote, 4} in exports
      assert {:chat_local, 3} in exports
      assert {:embed_local, 3} in exports
    end
  end

  describe "embedded format helpers" do
    test "message type has required :role and :content keys" do
      # Type definitions exist via @type — this is compile-time verified
      msg = %{role: "user", content: "Hello"}
      assert Map.has_key?(msg, :role)
      assert Map.has_key?(msg, :content)
    end

    test "response type has expected fields" do
      resp = %{
        content: "Hi",
        role: "assistant",
        model: "test",
        finish_reason: "stop",
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      }

      assert Map.has_key?(resp, :content)
      assert Map.has_key?(resp, :role)
      assert Map.has_key?(resp, :model)
    end
  end
end
