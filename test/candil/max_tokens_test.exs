defmodule Candil.MaxTokensTest do
  @moduledoc """
  El `max_tokens` decide cuanto puede decir un modelo, y **el razonamiento
  cuenta dentro**.

  Medido el 2026-10-22 con `agenta1` (que razona): con `max_tokens: 512` la
  respuesta vino **vacia** con `finish_reason: "length"` —el presupuesto se lo
  llevo el razonamiento— y con 2000 vino una respuesta de verdad.

  Tres cosas:

  1. El default global es **4096**, no 512.
  2. Un modelo puede declarar su propio `max_tokens` (el que razona mucho
     necesita el suyo).
  3. Una respuesta vacia con `finish_reason: "length"` **avisa**: devolver
     eso como un 200 con contenido vacio es la forma de que un fallo parezca
     un exito.
  """

  use ExUnit.Case, async: false

  alias Candil.Model
  alias Candil.RequestBuilder

  describe "el default" do
    test "son 4096, no 512" do
      body = RequestBuilder.build_openai_body("coder", [%{role: "user", content: "hola"}], [])

      assert body.max_tokens == 4096
    end

    test "tambien en el cuerpo de anthropic" do
      body = RequestBuilder.build_anthropic_body("coder", [%{role: "user", content: "hola"}], [])

      assert body.max_tokens == 4096
    end

    test "una llamada explicita manda sobre el default" do
      body =
        RequestBuilder.build_openai_body("coder", [%{role: "user", content: "hola"}],
          max_tokens: 100
        )

      assert body.max_tokens == 100
    end
  end

  describe "el max_tokens del modelo" do
    test "llega a la peticion" do
      model = %Model{
        alias: :agenta1,
        type: :local,
        engine: :llama_cpp,
        context_size: 262_144,
        max_tokens: 32_768
      }

      opts = Candil.Inference.put_max_tokens(model, [])

      assert opts[:max_tokens] == 32_768
    end

    test "un modelo sin max_tokens no toca la llamada" do
      model = %Model{alias: :coder, type: :local, engine: :llama_cpp}

      assert Candil.Inference.put_max_tokens(model, []) == []
    end

    test "una llamada explicita manda sobre el del modelo" do
      model = %Model{alias: :agenta1, type: :local, engine: :llama_cpp, max_tokens: 32_768}

      opts = Candil.Inference.put_max_tokens(model, max_tokens: 100)

      assert opts[:max_tokens] == 100
    end
  end

  describe "la respuesta truncada" do
    test "una respuesta vacia con finish_reason length avisa" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Candil.Inference.Chat.warn_truncated(
                     {:ok, %{content: "", finish_reason: "length", model: "agenta1"}}
                   )
        end)

      assert log =~ "vaci"
      assert log =~ "max_tokens"
    end

    test "una respuesta con contenido no avisa" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Candil.Inference.Chat.warn_truncated(%{
                     content: "hola",
                     finish_reason: "length",
                     model: "agenta1"
                   })
        end)

      assert log == ""
    end

    test "una respuesta vacia que no se trunco no avisa" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Candil.Inference.Chat.warn_truncated(%{
                     content: "",
                     finish_reason: "stop",
                     model: "agenta1"
                   })
        end)

      assert log == ""
    end
  end
end
