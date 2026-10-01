defmodule Candil.ContextTest do
  use ExUnit.Case, async: false

  alias Candil.Context
  alias Candil.Context.Session

  doctest Candil.Context.Session

  setup do
    # Clear everything these tests could have left behind, not a fixed list of
    # ids: a session created by one test leaks into the next one's `list/1`
    # and the failure points at the wrong line.
    for consumer <- Context.consumers(),
        session <- Context.list(consumer) do
      Context.delete(consumer, session.id)
    end

    :ok
  end

  describe "isolation between consumers" do
    test "the same session id under two consumers is two sessions" do
      # This is the whole point of keying on {consumer, id}. Two clients that
      # number their conversations from 1 will collide, and the failure would
      # be silent: the right number of messages from the wrong conversation.
      assert :ok = Context.append_message(:posadero, "s1", "user", "secreto del vault")
      assert :ok = Context.append_message(:opencode, "s1", "user", "hola, assistant")

      assert {:ok, posadero} = Context.get(:posadero, "s1")
      assert {:ok, opencode} = Context.get(:opencode, "s1")

      assert [%{content: "secreto del vault"}] = posadero.messages
      assert [%{content: "hola, assistant"}] = opencode.messages
    end

    test "deleting one consumer's session leaves the other's" do
      assert :ok = Context.append_message(:posadero, "s1", "user", "a")
      assert :ok = Context.append_message(:opencode, "s1", "user", "b")

      assert :ok = Context.delete(:posadero, "s1")
      assert Context.get(:posadero, "s1") == {:error, :not_found}
      assert {:ok, _} = Context.get(:opencode, "s1")
    end

    test "counts and lists are per consumer" do
      Context.append_message(:posadero, "s1", "user", "a")
      Context.append_message(:posadero, "s2", "user", "b")
      Context.append_message(:opencode, "s1", "user", "c")

      assert Context.count(:posadero) == 2
      assert Context.count(:opencode) == 1
      assert Context.consumers() |> Enum.sort() == [:opencode, :posadero]
    end
  end

  describe "create/1" do
    test "is idempotent" do
      {:ok, first} = Context.create(:posadero, "s1")
      assert :ok = Context.append_message(:posadero, "s1", "user", "hola")
      {:ok, second} = Context.create(:posadero, "s1")

      assert first.id == second.id
      assert length(second.messages) == 1
    end

    test "append_message creates the session if it is missing" do
      assert Context.get(:posadero, "nueva") == {:error, :not_found}
      assert :ok = Context.append_message(:posadero, "nueva", "user", "hola")
      assert {:ok, session} = Context.get(:posadero, "nueva")
      assert length(session.messages) == 1
    end
  end

  describe "update/3" do
    test "applies a function and stores the result" do
      {:ok, _} = Context.create(:posadero, "s1")

      assert :ok =
               Context.update(:posadero, "s1", &%{&1 | model_current: :coder})

      assert {:ok, session} = Context.get(:posadero, "s1")
      assert session.model_current == :coder
    end

    test "reports not found rather than creating" do
      assert Context.update(:posadero, "nope", & &1) == {:error, :not_found}
    end
  end

  # Stamping last_used_at explicitly rather than sleeping. Three creates in a
  # row land inside the same microsecond often enough that a sleep-based
  # ordering test is a coin flip.
  defp stamp(consumer, id, minutes_ago) do
    {:ok, session} = Context.create(consumer, id)
    at = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
    Context.update(consumer, id, &%{&1 | last_used_at: at, updated_at: at})
  end

  describe "list/1 ordering" do
    test "most recently used first" do
      stamp(:posadero, "s1", 3)
      stamp(:posadero, "s2", 2)
      stamp(:posadero, "s3", 1)

      assert [%{id: "s3"}, %{id: "s2"}, %{id: "s1"}] = Context.list(:posadero)
    end

    test "touching a session moves it to the front" do
      stamp(:posadero, "s1", 3)
      stamp(:posadero, "s2", 2)
      stamp(:posadero, "s3", 1)

      {:ok, session} = Context.get(:posadero, "s1")
      now = DateTime.utc_now()
      Context.update(:posadero, "s1", &%{&1 | last_used_at: now, updated_at: now})

      assert [%{id: "s1"} | _] = Context.list(:posadero)
      assert %{id: "s1"} = session
    end
  end

  describe "gc/1 TTL" do
    test "collects a session whose last_used_at is old" do
      {:ok, session} = Context.create(:gc_test, "s1")
      old = DateTime.add(DateTime.utc_now(), -3_600, :second)
      :ets.insert(Context.table(), {{:gc_test, "s1"}, %{session | last_used_at: old}})

      assert {:ok, %{ttl: 1}} = Context.gc(ttl_seconds: 3_600)
      assert Context.get(:gc_test, "s1") == {:error, :not_found}
    end

    test "keeps a session inside the window" do
      {:ok, _} = Context.create(:gc_test, "s2")
      assert {:ok, %{ttl: 0}} = Context.gc(ttl_seconds: 3_600)
      assert {:ok, _} = Context.get(:gc_test, "s2")
    end
  end

  describe "gc/1 LRU" do
    test "evicts the least recently used above max_sessions" do
      stamp(:gc_test, "s1", 3)
      stamp(:gc_test, "s2", 2)
      stamp(:gc_test, "s3", 1)

      # s1 is the oldest by last_used_at, so it goes.
      assert {:ok, %{lru: 1}} = Context.gc(ttl_seconds: 86_400, max_sessions: 2)
      assert Context.get(:gc_test, "s1") == {:error, :not_found}
      assert {:ok, _} = Context.get(:gc_test, "s2")
      assert {:ok, _} = Context.get(:gc_test, "s3")
    end

    test "leaves everything alone below the limit" do
      for id <- ["s1", "s2"], do: Context.create(:gc_test, id)
      assert {:ok, %{lru: 0}} = Context.gc(ttl_seconds: 86_400, max_sessions: 5)
    end

    test "a zero max would otherwise loop forever" do
      {:ok, _} = Context.create(:gc_test, "s1")
      assert {:ok, %{lru: 1}} = Context.gc(max_sessions: 0)
    end
  end

  describe "Session.tokens/1" do
    test "grows with content and with the summary" do
      session = Session.new(:c, "s")
      assert Session.tokens(session) == 0

      session = Session.add_message(session, "user", String.duplicate("a", 400))
      with_message = Session.tokens(session)
      assert with_message > 0

      with_summary = Session.tokens(%{session | summary: String.duplicate("b", 400)})
      assert with_summary > with_message
    end
  end

  describe "Session.live_messages/1" do
    test "drops the summarised prefix without deleting anything" do
      session =
        Enum.reduce(["a", "b", "c"], Session.new(:c, "s"), fn msg, acc ->
          Session.add_message(acc, "user", msg)
        end)

      summarised = %{session | summarised_upto: 2, summary: "a y b"}

      assert Session.live_messages(summarised) == [%{role: "user", content: "c"}]
      # The evidence stays. A user who wants to know what was summarised can
      # read the actual messages.
      assert length(summarised.messages) == 3
    end
  end

  describe "Session.needs_summary?/2" do
    test "is false for a short session" do
      refute Session.needs_summary?(Session.new(:c, "s"))
    end

    test "is true past the message threshold" do
      session =
        Enum.reduce(1..6, Session.new(:c, "s"), fn n, acc ->
          Session.add_message(acc, "user", "mensaje \#{n}")
        end)

      assert Session.needs_summary?(session, after_messages: 5)
    end

    test "is true past the token threshold" do
      session = Session.add_message(Session.new(:c, "s"), "user", String.duplicate("a", 4_000))
      assert Session.needs_summary?(session, after_tokens: 100)
    end

    test "a summarised session stops counting the old messages" do
      session =
        Enum.reduce(1..6, Session.new(:c, "s"), fn n, acc ->
          Session.add_message(acc, "user", "mensaje \#{n}")
        end)

      summarised = %{session | summarised_upto: 6}
      refute Session.needs_summary?(summarised, after_messages: 5)
    end
  end
end
