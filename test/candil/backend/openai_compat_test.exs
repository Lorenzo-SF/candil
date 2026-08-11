defmodule Candil.Backend.OpenAICompatTest do
  use ExUnit.Case, async: false
  import Mox

  alias Candil.{Error, HTTPAdapterMock, Model}
  alias Candil.Backend.OpenAICompat
  alias Apero.Http.{Request, Response}

  setup :verify_on_exit!

  setup do
    Application.put_env(:apero, :http_adapter, HTTPAdapterMock)
    :ok
  end

  defp expect_post(url_suffix, status, body) do
    expect(HTTPAdapterMock, :request, fn %Request{method: :post, url: url} = req ->
      assert String.ends_with?(url, url_suffix)
      assert req.headers != []
      {:ok, %Response{status: status, headers: [{"content-type", "application/json"}], body: body}}
    end)
  end

  defp model do
    %Model{alias: "gpt-4o-mini", name: "gpt-4o-mini", type: :remote, provider: :openai}
  end

  describe "chat/3" do
    test "returns content from a 200 response" do
      expect_post("/v1/chat/completions", 200, %{
        "choices" => [%{"message" => %{"content" => "hello from the model"}}]
      })

      assert {:ok, %{content: "hello from the model"}} =
               OpenAICompat.chat(model(), [%{role: "user", content: "hi"}], [])
    end

    test "maps 401 to auth_error" do
      expect_post("/v1/chat/completions", 401, %{"error" => %{"message" => "bad key"}})

      assert {:error, %Error{reason: :auth_error}} =
               OpenAICompat.chat(model(), [%{role: "user", content: "hi"}], [])
    end

    test "maps 429 to rate_limited" do
      expect_post("/v1/chat/completions", 429, %{"error" => %{"message" => "slow down"}})

      assert {:error, %Error{reason: :rate_limited}} =
               OpenAICompat.chat(model(), [%{role: "user", content: "hi"}], retry: false)
    end

    test "maps 500 to server_error" do
      expect_post("/v1/chat/completions", 500, %{"error" => %{"message" => "boom"}})

      assert {:error, %Error{reason: :server_error}} =
               OpenAICompat.chat(model(), [%{role: "user", content: "hi"}], retry: false)
    end

    test "returns error for network failure" do
      expect(HTTPAdapterMock, :request, fn %Request{} ->
        {:error, %Apero.Http.Error{reason: :econnrefused}}
      end)

      assert {:error, %Error{}} = OpenAICompat.chat(model(), [%{role: "user", content: "hi"}], [])
    end
  end

  describe "chat_stream/3" do
    test "returns a chunk stream on 200" do
      expect(HTTPAdapterMock, :stream, fn %Request{method: :post, body: %{stream: true}}, _acc, _fun, _opts ->
        {:ok, []}
      end)

      assert {:ok, stream} =
               OpenAICompat.chat_stream(model(), [%{role: "user", content: "hi"}], [])

      assert is_struct(stream, Stream)
    end
  end

  describe "embed/3" do
    test "returns vectors from a 200 response" do
      expect_post("/v1/embeddings", 200, %{
        "data" => [%{"embedding" => [0.1, 0.2, 0.3]}]
      })

      assert {:ok, [[0.1, 0.2, 0.3]]} = OpenAICompat.embed(model(), ["hello"], [])
    end

    test "returns error on non-200" do
      expect_post("/v1/embeddings", 400, %{"error" => %{"message" => "nope"}})

      assert {:error, %Error{reason: :http_error}} = OpenAICompat.embed(model(), ["hello"], [])
    end
  end

  describe "models/0" do
    test "delegates to Config.list_models" do
      assert is_list(OpenAICompat.models())
    end
  end
end