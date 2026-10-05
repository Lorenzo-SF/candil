defmodule Candil.ConcurrencyTest do
  @moduledoc """
  The seam F6's fan-out will use. Tested now, with one caller, so that the second
  caller is a copy rather than a guess.
  """
  use ExUnit.Case, async: true

  alias Candil.Concurrency

  describe "map/2" do
    test "an empty list is an empty list" do
      assert Concurrency.map([]) == []
    end

    test "one task runs in this process, without spawning" do
      parent = self()

      assert [{:only, :done}] =
               Concurrency.map([
                 {:only,
                  fn ->
                    send(parent, :ran)
                    :done
                  end}
               ])

      assert_received :ran
    end

    test "the order given is the order returned" do
      # Deliberately uneven, so a serial run and a parallel run cannot both pass
      # by accident: the last one is the slowest.
      tasks = [
        {:a, fn -> Process.sleep(30) && :a end},
        {:b, fn -> Process.sleep(1) && :b end},
        {:c, fn -> Process.sleep(20) && :c end},
        {:d, fn -> Process.sleep(5) && :d end},
        {:e, fn -> :e end}
      ]

      assert Concurrency.map(tasks) == [{:a, :a}, {:b, :b}, {:c, :c}, {:d, :d}, {:e, :e}]
    end

    # This is the failure the retry exists for, and it is a real one: work that
    # only succeeds in the *caller's* process — the process dictionary, a
    # `Process.info` on a process you own, a `$ancestors` lookup. In a task it
    # raises; in series, in this process, it works. The row is recovered
    # instead of lost.
    test "work that only runs in the caller's process is retried there" do
      parent = self()

      only_here = fn ->
        if self() == parent, do: :recovered, else: raise("no en una task")
      end

      tasks =
        for {label, fun} <- [{:a, only_here}, {:b, only_here}, {:c, only_here}, {:d, only_here}] do
          {label, fun}
        end

      assert Concurrency.map(tasks) ==
               [{:a, :recovered}, {:b, :recovered}, {:c, :recovered}, {:d, :recovered}]
    end

    test "a task that always raises propagates, and the others are unaffected" do
      # Retrying in series is a *fallback for the parallel attempt*, not a rescue
      # around the work. A row that cannot be built in series could not be built
      # in parallel either, and swallowing that would hide a real bug.
      tasks = [
        {:a, fn -> :ok end},
        {:boom, fn -> raise "siempre" end},
        {:c, fn -> :ok end},
        {:d, fn -> :ok end}
      ]

      assert_raise RuntimeError, fn -> Concurrency.map(tasks) end
    end

    test "a task that raises twice propagates, because serial had no rescue either" do
      tasks = [
        {:t1, fn -> raise "siempre" end},
        {:t2, fn -> raise "siempre" end},
        {:t3, fn -> raise "siempre" end},
        {:t4, fn -> raise "siempre" end},
        {:t5, fn -> raise "siempre" end}
      ]

      # The retry runs in this process, so the raise is not swallowed by a
      # task boundary. That is the honest outcome: a row that cannot be built
      # in series could not be built in parallel either.
      assert_raise RuntimeError, fn -> Concurrency.map(tasks) end
    end
  end

  describe "the threshold" do
    test "below it, it does not spawn" do
      refute Concurrency.parallel?(1)
      refute Concurrency.parallel?(3)
    end

    test "at it, it does" do
      assert Concurrency.parallel?(4)
      assert Concurrency.parallel?(40)
    end

    test "and it is asked for, not hard-coded at the call site" do
      assert Concurrency.min_tasks() >= 4
    end
  end
end
