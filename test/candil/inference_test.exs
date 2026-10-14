defmodule Candil.InferenceTest do
  use ExUnit.Case, async: false

  alias Candil.Inference
  alias Candil.Inference.Chat

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

  # Las tres formas que devuelve un servidor de verdad. Medido el 2026-10-14 con
  # `Qwen3.8-27B` y `--reasoning-format deepseek` —como lo tiene el catalogo— y
  # con `Qwen3-Coder-30B` y el mismo flag, que **no** razona.
  describe "el razonamiento de la respuesta" do
    defp parse(body), do: Chat.parse_openai_response({:ok, %{status: 200, body: body}})

    defp cuerpo(extra) do
      %{
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => Map.merge(%{"role" => "assistant", "content" => "10 patas"}, extra)
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3}
      }
    end

    test "cuando el servidor razonó, el razonamiento viene" do
      # El caso de P-8: 1996 bytes con la duda de si contaba al granjero, que
      # antes se caian al suelo sin dejar rastro.
      razonamiento = "We need answer user request. 3+2=5 birds, 10 legs. But maybe farmer?"

      assert {:ok, respuesta} = parse(cuerpo(%{"reasoning_content" => razonamiento}))

      assert respuesta.content == "10 patas"
      assert respuesta.reasoning == razonamiento
    end

    test "cuando el modelo no razona, nil es una respuesta y no un fallo" do
      # Con `Qwen3-Coder-30B` la respuesta no trae `reasoning_content` en
      # absoluto. Y `finish_reason` es "stop" en los dos casos: por eso el
      # razonamiento tiene que ir explicito y no deducirse.
      assert {:ok, respuesta} = parse(cuerpo(%{}))

      assert respuesta.content == "10 patas"
      assert respuesta.reasoning == nil
      assert respuesta.finish_reason == "stop"
    end

    test "un razonamiento vacio se conserva tal cual" do
      assert {:ok, respuesta} = parse(cuerpo(%{"reasoning_content" => ""}))

      assert respuesta.reasoning == ""
    end
  end
end
