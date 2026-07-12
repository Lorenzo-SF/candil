defmodule Candil.EnginePoolTest do
  use ExUnit.Case, async: false

  alias Candil.EnginePool

  # Drain any pre-existing engines from the pool so each test starts clean.
  # This is defensive: in practice the pool is empty because no real engines
  # are started during tests.
  setup do
    # Evict all existing entries and save to restore on exit
    entries = do_drain([])
    on_exit(fn -> do_restore(entries) end)
    :ok
  end

  defp do_drain(acc) do
    case EnginePool.evict() do
      :empty -> acc
      engine -> do_drain([engine | acc])
    end
  end

  defp do_restore([]), do: :ok
  defp do_restore([e | rest]), do: (EnginePool.put(e); do_restore(rest))

  test "put and get LRU ordering" do
    e1 = %{alias: :e1}
    e2 = %{alias: :e2}
    e3 = %{alias: :e3}

    EnginePool.put(e1)
    EnginePool.put(e2)
    EnginePool.put(e3)

    assert EnginePool.get() == e1
    assert EnginePool.get() == e2

    EnginePool.put(e1)
    assert EnginePool.get() == e3
  end

  test "evict removes least recently used" do
    e1 = %{alias: :e1}
    e2 = %{alias: :e2}
    EnginePool.put(e1)
    EnginePool.put(e2)

    assert EnginePool.evict() == e1
    assert EnginePool.get() == e2
  end

  test "registering existing engine updates order" do
    e1 = %{alias: :e1}
    EnginePool.put(e1)
    EnginePool.put(e1) # duplicate
    assert EnginePool.get() == e1
    assert EnginePool.get() == e1
  end

  test "get from empty pool returns :empty" do
    assert EnginePool.get() == :empty
  end
end
