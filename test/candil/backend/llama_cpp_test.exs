defmodule Candil.Backend.LlamaCppTest do
  use ExUnit.Case, async: false
  import Mox

  alias Candil.{Backend.LlamaCpp, HTTPAdapterMock}

  setup :verify_on_exit!

  setup do
    stub(HTTPAdapterMock, :request, fn %Apero.Http.Request{} ->
      {:error, %Apero.Http.Error{reason: :econnrefused}}
    end)

    :ok
  end

  describe "chat/3" do
    test "returns backend_unavailable until a real engine is wired" do
      assert {:error, %Candil.Error{reason: :backend_unavailable}} =
               LlamaCpp.chat("test-model", [%{role: "user", content: "hi"}], [])
    end

    test "chat_stream/3 returns backend_unavailable" do
      assert {:error, %Candil.Error{reason: :backend_unavailable}} =
               LlamaCpp.chat_stream("test-model", [%{role: "user", content: "hi"}], [])
    end
  end

  describe "embed/3" do
    test "delegates to Embeddings.embed_batch (error path for unreachable host)" do
      assert {:error, _} =
               LlamaCpp.embed("test-model", ["hello"], url: "http://192.0.2.1:1", timeout_ms: 100)
    end
  end

  describe "models/0" do
    test "delegates to Config.list_models" do
      assert is_list(LlamaCpp.models())
    end
  end
end