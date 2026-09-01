defmodule Candil.StreamTest do
  use ExUnit.Case, async: true
  import Mox

  alias Candil.{Error, HTTPAdapterMock, Model, Provider, Stream}
  alias Apero.Http.Request

  setup :verify_on_exit!

  setup do
    Application.put_env(:apero, :http_adapter, HTTPAdapterMock)
    :ok
  end

  describe "chat/4 (local)" do
    test "returns error when engine not running" do
      callback = fn _chunk -> :ok end

      result = Stream.chat(:nonexistent_model, [%{role: "user", content: "Hello"}], callback, [])

      assert {:error,
              %Error{reason: :engine_not_running, context: %{engine_alias: :nonexistent_model}}} =
               result
    end
  end

  describe "chat/4 (remote providers via do_stream)" do
    defp model, do: %Model{alias: "m", name: "model-x", type: :remote}

    defp openai_provider do
      %Provider{
        alias: :openai_test,
        type: :openai,
        base_url: "http://127.0.0.1:9999",
        api_key: "sk-test",
        headers: []
      }
    end

    defp ollama_provider do
      %Provider{alias: :ollama_test, type: :ollama, base_url: "http://127.0.0.1:11434", headers: []}
    end

    defp anthropic_provider do
      %Provider{
        alias: :anthropic_test,
        type: :anthropic,
        base_url: "http://127.0.0.1:9999",
        api_key: "sk-ant",
        headers: []
      }
    end

    test "openai provider stream returns :ok" do
      expect(HTTPAdapterMock, :stream, fn %Request{}, _acc, _fun, _opts -> {:ok, []} end)

      callback = fn _chunk -> :ok end

      assert :ok =
               Stream.chat(
                 model(),
                 openai_provider(),
                 [%{role: "user", content: "hi"}],
                 callback,
                 timeout_ms: 500, receive_timeout_ms: 100
               )
    end

    test "ollama provider stream returns :ok" do
      expect(HTTPAdapterMock, :stream, fn %Request{}, _acc, _fun, _opts -> {:ok, []} end)

      callback = fn _chunk -> :ok end

      assert :ok =
               Stream.chat(
                 model(),
                 ollama_provider(),
                 [%{role: "user", content: "hi"}],
                 callback,
                 timeout_ms: 500, receive_timeout_ms: 100
               )
    end

    test "anthropic provider stream returns :ok" do
      expect(HTTPAdapterMock, :stream, fn %Request{}, _acc, _fun, _opts -> {:ok, []} end)

      callback = fn _chunk -> :ok end

      assert :ok =
               Stream.chat(
                 model(),
                 anthropic_provider(),
                 [%{role: "user", content: "hi"}],
                 callback,
                 timeout_ms: 500, receive_timeout_ms: 100
               )
    end
  end

  describe "extract_sse_events/1 (stateful SSE parser — CA-2)" do
    test "splits a complete event" do
      {events, rest} = Stream.extract_sse_events("data: hello\n\n")

      assert events == ["hello"]
      assert rest == ""
    end

    test "splits multiple events" do
      {events, rest} = Stream.extract_sse_events("data: a\n\ndata: b\n\ndata: c\n\n")
      assert events == ["a", "b", "c"]
      assert rest == ""
    end

    test "preserves partial event in rest" do
      {events, rest} = Stream.extract_sse_events("data: a\n\ndata: par")
      assert events == ["a"]
      assert rest == "data: par"
    end

    test "accepts CRLF line endings" do
      {events, rest} = Stream.extract_sse_events("data: a\r\n\r\ndata: b\r\n\r\n")
      assert events == ["a", "b"]
      assert rest == ""
    end

    test "tolerates mixed LF / CRLF / no line ending" do
      {events, rest} = Stream.extract_sse_events("data: a\n\ndata: b\r\n\r\ndata: c")
      assert events == ["a", "b"]
      assert rest == "data: c"
    end

    test "handles JSON payloads that span multiple lines" do
      chunk = "data: {\"a\": 1,\n\"b\": 2}\n\n"
      {events, rest} = Stream.extract_sse_events(chunk)
      assert events == ["{\"a\": 1,\n\"b\": 2}"]
      assert rest == ""
    end

    test "ignores comment lines" do
      {events, rest} = Stream.extract_sse_events(": keep-alive\n\ndata: real\n\n")
      assert events == ["real"]
      assert rest == ""
    end
  end
end
