defmodule Candil.Agents.CrashesStoreTest do
  @moduledoc """
  El presupuesto de crashes por agente: registra, cuenta dentro de la ventana,
  olvida fuera de ella, y no mezcla nombres. P-9, segunda mitad.
  """

  use ExUnit.Case, async: false

  alias Candil.Agents.Crashes

  setup do
    name = "crash-#{System.unique_integer([:positive])}"
    on_exit(fn -> Crashes.forget(name) end)
    %{name: name}
  end

  test "sin crashes, la cuenta es cero", %{name: name} do
    assert Crashes.count(name, 1_000) == 0
    assert {:error, :not_found} = Crashes.load(name)
  end

  test "registrar suma, y los que quedan fuera de la ventana no cuentan", %{name: name} do
    now = 10_000
    window = Crashes.window_ms()

    Crashes.record(name, now - window - 1)
    Crashes.record(name, now - 100)
    Crashes.record(name, now)

    assert Crashes.count(name, now) == 2
  end

  test "cada nombre es su sitio", %{name: name} do
    otro = name <> "-otro"
    on_exit(fn -> Crashes.forget(otro) end)

    now = 5_000
    Crashes.record(name, now)
    Crashes.record(otro, now)
    Crashes.record(otro, now)

    assert Crashes.count(name, now) == 1
    assert Crashes.count(otro, now) == 2
  end

  test "olvidar borra, y no falla si no había nada", %{name: name} do
    Crashes.record(name, 1_000)

    assert :ok = Crashes.forget(name)
    assert Crashes.count(name, 1_000) == 0
    assert :ok = Crashes.forget(name)
  end

  test "un nombre `nil` no registra ni cuenta", _ctx do
    assert :ok = Crashes.record(nil, 1_000)
    assert Crashes.count(nil, 1_000) == 0
  end

  test "la tabla no es del agente: es del almacén" do
    owner = :ets.info(Crashes.table(), :owner)

    assert :ets.info(Crashes.table(), :named_table) == true
    assert is_pid(owner)
    assert owner != self()
    assert Process.alive?(owner)
  end

  test "prune/2 descarta lo que queda fuera de la ventana" do
    now = 10_000
    window = Crashes.window_ms()

    assert Crashes.prune([now - window - 1, now - 100, now], now) == [now - 100, now]
  end
end
