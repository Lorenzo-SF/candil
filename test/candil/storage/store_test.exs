defmodule Candil.Storage.StoreTest do
  use ExUnit.Case, async: false

  alias Candil.Storage.{Adapter, ETS, Store}

  setup do
    on_exit(fn ->
      Store.delete(:k)
      Store.delete(:a)
      Store.delete(:b)
    end)

    :ok
  end

  test "get de algo que no existe es not_found" do
    assert {:error, :not_found} = Store.get(:nope)
  end

  test "put y get" do
    assert :ok = Store.put(:k, "v")
    assert {:ok, "v"} = Store.get(:k)
  end

  test "put reemplaza" do
    Store.put(:k, "v1")
    Store.put(:k, "v2")
    assert {:ok, "v2"} = Store.get(:k)
  end

  test "delete" do
    Store.put(:k, "v")
    assert :ok = Store.delete(:k)
    assert {:error, :not_found} = Store.get(:k)
  end

  test "list y count" do
    Store.put(:a, 1)
    Store.put(:b, 2)
    assert Store.count() >= 2
    assert 1 in Store.list()
    assert 2 in Store.list()
  end

  test "adapter/0 devuelve el adaptador activo" do
    assert Store.adapter() == ETS
  end

  test "ETS implementa el behaviour" do
    assert {:ok, _table} = ETS.init([])
  end
end
