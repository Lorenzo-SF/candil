defmodule Candil.StreamTest do
  use ExUnit.Case, async: true

  alias Candil.{Error, Stream}

  describe "chat/4 (local)" do
    test "returns error when engine not running" do
      callback = fn _chunk -> :ok end

      result = Stream.chat(:nonexistent_model, [%{role: "user", content: "Hello"}], callback, [])

      assert {:error,
              %Error{reason: :engine_not_running, context: %{engine_alias: :nonexistent_model}}} =
               result
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
