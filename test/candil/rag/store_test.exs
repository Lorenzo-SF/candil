defmodule Candil.RAG.StoreTest do
  @moduledoc """
  El store del RAG: indices y chunks.

  ## Por que este test es **sincronizado**

  `Candil.RAG.Store.reset/0` **borra todos los indices y todos sus chunks**
  ✓, y las tablas de ETS son **globales** ✓. Un test asincrono que lo llamara
  ✓ se llevaria por delante los indices de los demas ✓. Por eso este
  fichero es `async: false` ✓: ExUnit corre los sincronizados **despues** de
  los asincronos ✓, nunca a la vez ✓.

  Es la unica prueba que toca el store entero ✓ — y por eso esta aqui
  ✓, y no en `rag_test.exs` ✓, que es asincrono ✓.
  """

  use ExUnit.Case, async: false

  alias Candil.RAG

  defp unique_index, do: "test:#{System.unique_integer([:positive])}"

  test "reset/0 borra todos los indices y todos sus chunks" do
    name = unique_index()
    on_exit(fn -> RAG.drop_index(name) end)

    :ok = RAG.create_index(name)
    {:ok, 1} = RAG.index(name, "Uno.")

    assert Candil.RAG.Store.count_chunks(name) == 1

    assert :ok = Candil.RAG.Store.reset()

    assert Candil.RAG.Store.list_indexes() == []
    assert Candil.RAG.Store.count_chunks(name) == 0
  end

  test "y delete_missing_chunks/2 borra solo los que no estan en la lista" do
    name = unique_index()
    on_exit(fn -> RAG.drop_index(name) end)

    :ok = RAG.create_index(name)
    {:ok, 3} = RAG.index(name, "Uno. Dos. Tres.")

    [first, second, third] = Candil.RAG.Store.get_chunks(name)

    # Se quedan dos de tres ✓, así que se borra **uno** ✓.
    assert 1 = Candil.RAG.Store.delete_missing_chunks(name, [first.id, third.id])
    assert Candil.RAG.Store.count_chunks(name) == 2

    # Y el que se queda es el que se pidio, no otro.
    assert Enum.map(Candil.RAG.Store.get_chunks(name), & &1.id) |> Enum.sort() ==
             Enum.sort([first.id, third.id])

    assert second.id not in Enum.map(Candil.RAG.Store.get_chunks(name), & &1.id)
  end
end
