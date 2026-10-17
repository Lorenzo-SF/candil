defmodule Candil.Context.IsolationTest do
  use ExUnit.Case, async: false

  alias Candil.Storage.Store

  # El que NO puede cambiar: dos sesiones con el mismo id bajo distintos
  # consumidores no se mezclan. La partición vive en la clave, no en el struct.
  test "dos consumidores con el mismo id no se mezclan" do
    key_a = {:consumer_a, "s1"}
    key_b = {:consumer_b, "s1"}

    Store.put(key_a, "historial de A")
    Store.put(key_b, "historial de B")

    assert {:ok, "historial de A"} = Store.get(key_a)
    assert {:ok, "historial de B"} = Store.get(key_b)

    Store.delete(key_a)
    Store.delete(key_b)
  end
end
