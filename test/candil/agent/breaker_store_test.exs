defmodule Candil.Agents.BreakerStoreTest do
  @moduledoc """
  El circuito del breaker, fuera del proceso del agente: guarda, lee,
  olvida — y no mezcla nombres. Es lo que hace que un circuito abierto
  sobreviva al reinicio del agente (P-9, primera mitad).
  """

  use ExUnit.Case, async: false

  alias Candil.Agents.Breaker
  alias Candil.Agents.Breakers

  setup do
    name = "brk-#{System.unique_integer([:positive])}"
    on_exit(fn -> Breakers.forget(name) end)
    %{name: name}
  end

  test "lo que se guarda se lee, y lo que no hay no se inventa", %{name: name} do
    assert {:error, :not_found} = Breakers.load(name)

    circuito = Breaker.new(breaker_threshold: 2)
    assert :ok = Breakers.save(name, circuito)
    assert {:ok, ^circuito} = Breakers.load(name)
  end

  test "guardar reemplaza: el último circuito es el ÚLTIMO", %{name: name} do
    Breakers.save(name, Breaker.new(breaker_threshold: 2))
    abierto = Breaker.record(Breaker.new(breaker_threshold: 2), :timeout, 1)
    abierto = Breaker.record(abierto, :timeout, 2)
    Breakers.save(name, abierto)

    assert {:ok, leido} = Breakers.load(name)
    assert Breaker.check(leido, 3) == :open
  end

  test "cada nombre es su sitio", %{name: name} do
    otro = name <> "-otro"
    on_exit(fn -> Breakers.forget(otro) end)

    Breakers.save(name, Breaker.new(breaker_threshold: 2))
    Breakers.save(otro, Breaker.new(breaker_threshold: 7))

    assert {:ok, a} = Breakers.load(name)
    assert {:ok, b} = Breakers.load(otro)
    assert a.threshold == 2
    assert b.threshold == 7
  end

  test "olvidar borra, y no falla si no había nada", %{name: name} do
    Breakers.save(name, Breaker.new())

    assert :ok = Breakers.forget(name)
    assert {:error, :not_found} = Breakers.load(name)
    assert :ok = Breakers.forget(name)
  end

  test "un nombre `nil` no guarda nada", _ctx do
    assert :ok = Breakers.save(nil, Breaker.new())
    assert {:error, :not_found} = Breakers.load(nil)
  end

  test "la tabla no es del agente: es del almacén" do
    owner = :ets.info(Breakers.table(), :owner)

    assert :ets.info(Breakers.table(), :named_table) == true
    assert is_pid(owner)
    assert owner != self()
    assert Process.alive?(owner)
  end
end
