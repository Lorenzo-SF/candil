defmodule Candil.Agents.SnapshotsTest do
  @moduledoc """
  El almacén del «último estado estable»: guarda, lee, olvida — y no mezcla
  nombres. F5.4.
  """

  use ExUnit.Case, async: false

  alias Candil.Agents.Snapshots

  setup do
    name = "snap-#{System.unique_integer([:positive])}"
    on_exit(fn -> Snapshots.forget(name) end)
    %{name: name}
  end

  test "lo que se guarda se lee, y lo que no hay no se inventa", %{name: name} do
    assert {:error, :not_found} = Snapshots.load(name)

    assert :ok = Snapshots.save(name, %{rounds: 3})
    assert {:ok, %{rounds: 3}} = Snapshots.load(name)
  end

  test "guardar reemplaza: el último estado estable es el ÚLTIMO", %{name: name} do
    Snapshots.save(name, %{rounds: 1})
    Snapshots.save(name, %{rounds: 2})

    assert {:ok, %{rounds: 2}} = Snapshots.load(name)
  end

  test "cada nombre es su sitio", %{name: name} do
    otro = name <> "-otro"
    on_exit(fn -> Snapshots.forget(otro) end)

    Snapshots.save(name, %{rounds: 1})
    Snapshots.save(otro, %{rounds: 9})

    assert {:ok, %{rounds: 1}} = Snapshots.load(name)
    assert {:ok, %{rounds: 9}} = Snapshots.load(otro)
  end

  test "olvidar borra, y no falla si no había nada", %{name: name} do
    Snapshots.save(name, %{rounds: 1})

    assert :ok = Snapshots.forget(name)
    assert {:error, :not_found} = Snapshots.load(name)
    assert :ok = Snapshots.forget(name)
  end

  test "la tabla no es del agente: es del almacén" do
    # Si la tabla fuera del agente, moriría con él y el reinicio no tendría de
    # dónde leer — que es el fallo entero que este módulo existe para no
    # tener. El dueño es el proceso del almacén, que vive en el árbol.
    owner = :ets.info(Snapshots.table(), :owner)

    assert :ets.info(Snapshots.table(), :named_table) == true
    assert is_pid(owner)
    assert owner != self()
    assert Process.alive?(owner)
  end
end
