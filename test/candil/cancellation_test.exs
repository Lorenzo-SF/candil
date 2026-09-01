defmodule Candil.CancellationTest do
  use ExUnit.Case, async: false

  alias Candil.Cancellation

  setup do
    start_supervised(Cancellation)
    :ok
  end

  test "new_ref/0 returns unique references" do
    ref1 = Cancellation.new_ref()
    ref2 = Cancellation.new_ref()
    assert is_reference(ref1)
    assert is_reference(ref2)
    assert ref1 != ref2
  end

  test "register/done cycle keeps count consistent" do
    before = Cancellation.count()
    ref = Cancellation.new_ref()
    assert Cancellation.register(ref) == :ok
    assert Cancellation.count() == before + 1
    assert Cancellation.done(ref) == :ok
    assert Cancellation.count() == before
  end

  test "done/1 is idempotent" do
    before = Cancellation.count()
    ref = Cancellation.new_ref()
    Cancellation.register(ref)
    assert Cancellation.done(ref) == :ok
    assert Cancellation.done(ref) == :ok
    assert Cancellation.count() == before
  end

  test "cancel/1 returns :ok for in-flight ref" do
    ref = Cancellation.new_ref()
    Cancellation.register(ref)
    assert Cancellation.cancel(ref) == :ok
    assert Cancellation.cancelled?(ref)
  end

  test "cancel/1 returns :not_found for unknown ref" do
    ref = Cancellation.new_ref()
    assert Cancellation.cancel(ref) == :not_found
    refute Cancellation.cancelled?(ref)
  end

  test "cancelled?/1 returns false for unknown ref" do
    refute Cancellation.cancelled?(Cancellation.new_ref())
  end

  test "cancel persists across register/done lifecycle" do
    ref = Cancellation.new_ref()
    Cancellation.register(ref)
    Cancellation.cancel(ref)
    Cancellation.done(ref)

    # Cancellation is sticky — the cancelled set remembers the ref
    # even after done. (Useful for "you tried to cancel too late"
    # semantics.)
    assert Cancellation.cancelled?(ref)
  end
end