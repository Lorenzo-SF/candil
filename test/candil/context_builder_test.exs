defmodule Candil.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias Candil.Context.{Builder, PrefixManager, Session, Summarizer}

  doctest Candil.Context.Builder

  defp session_with(messages) do
    Enum.reduce(messages, Session.new(:c, "s"), fn text, acc ->
      Session.add_message(acc, "user", text)
    end)
  end

  describe "build/3" do
    test "passes the messages through when they fit" do
      {:ok, messages} = Builder.build(Session.new(:c, "s"), [%{role: "user", content: "hola"}])
      assert messages == [%{role: "user", content: "hola"}]
    end

    test "prepends a system prompt" do
      {:ok, messages} =
        Builder.build(Session.new(:c, "s"), [%{role: "user", content: "hola"}],
          system_prompt: "eres un asistente"
        )

      assert [%{role: "system", content: "eres un asistente"}, %{role: "user"}] = messages
    end

    test "fails loudly instead of truncating" do
      # A truncated conversation is one where the model answers a question it
      # was not asked, with no way for the caller to tell.
      long = [%{role: "user", content: String.duplicate("hola", 100)}]

      assert {:error, :context_exceeded} =
               Builder.build(Session.new(:c, "s"), long, context_size: 4)
    end

    test "a summary comes before the recent history" do
      session = %{session_with(["viejo"]) | summary: "un resumen"}

      {:ok, messages} = Builder.build(session, [%{role: "user", content: "nuevo"}])
      assert [first | _] = messages
      assert first.content =~ "un resumen"
      assert Enum.any?(messages, &(&1.content == "nuevo"))
    end

    test "summarised messages are not resent" do
      session = session_with(["a", "b", "c"])
      session = %{session | summarised_upto: 2, summary: "a y b"}

      {:ok, messages} = Builder.build(session, [%{role: "user", content: "ahora"}])
      texts = Enum.map(messages, & &1.content)
      refute "a" in texts
      refute "b" in texts
      assert "c" in texts
    end

    test "history is dropped from the front, never from the end" do
      # Dropping the newest would throw away the question just asked.
      long_a = String.duplicate("a", 3_000)
      long_b = String.duplicate("b", 3_000)
      session = session_with([long_a, long_b, "reciente"])

      {:ok, messages} =
        Builder.build(session, [%{role: "user", content: "pregunta"}],
          context_size: 900,
          margin_tokens: 100
        )

      texts = Enum.map(messages, & &1.content)
      # The question just asked survives, whatever else was dropped.
      assert "pregunta" in texts
      assert "reciente" in texts
      refute long_a in texts
    end
  end

  describe "Summarizer" do
    test "does nothing to a short session" do
      session = session_with(["hola"])
      assert {:ok, ^session} = Summarizer.maybe_summarize(session)
    end

    test "does nothing when no summariser model is configured" do
      # A context system that destroys history because a model was down is
      # worse than one that never summarises.
      session = session_with(List.duplicate("palabra", 4000))
      assert {:ok, ^session} = Summarizer.maybe_summarize(session, after_tokens: 10)
    end

    test "does nothing when the summariser model is unknown" do
      session = session_with(List.duplicate("palabra", 4000))

      assert {:ok, ^session} =
               Summarizer.maybe_summarize(session, model: :no_existe, after_tokens: 10)
    end
  end

  describe "PrefixManager" do
    setup do
      PrefixManager.flush()
      :ok
    end

    test "round-trips a prompt" do
      assert :ok = PrefixManager.put(:coder, "eres un asistente")
      assert {:ok, "eres un asistente"} = PrefixManager.get(:coder, "eres un asistente")
    end

    test "a different prompt is a miss, not a stale hit" do
      PrefixManager.put(:coder, "prompt v1")
      assert PrefixManager.get(:coder, "prompt v2") == :miss
    end

    test "a different model is a different entry" do
      # Two models with the same prompt do not share a prefix, because their
      # KV caches are not the same cache.
      PrefixManager.put(:coder, "compartido")
      assert PrefixManager.get(:verifier, "compartido") == :miss
    end

    test "stats starts at zero and reports the shape promised" do
      assert PrefixManager.stats() == %{hits: 0, misses: 0}
    end
  end
end
