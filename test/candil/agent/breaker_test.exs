defmodule Candil.Agents.BreakerTest do
  @moduledoc """
  El tercer cerrojo del §8.3, en puro: sin procesos, sin backends y sin
  dormir.

  El modulo recibe `now` como parametro justo para esto: el tiempo entra a
  mano y los casos raros —la sonda que llega un milisegundo antes, la que
  reaplaza el enfriamiento— se prueban sin esperar a nadie.
  """

  use ExUnit.Case, async: true

  alias Candil.Agents.Breaker

  describe "los numeros" do
    test "el defecto son 5 cuelgues y 30 s, los mismos del breaker de HTTP" do
      assert Breaker.defaults() == [threshold: 5, cooldown_ms: 30_000]
      assert %Breaker{threshold: 5, cooldown_ms: 30_000} = Breaker.new()
    end

    test "se configuran, y las claves que no son suyas se ignoran" do
      breaker = Breaker.new(breaker_threshold: 2, breaker_cooldown_ms: 50, timeout: 1_000)

      assert %Breaker{threshold: 2, cooldown_ms: 50} = breaker
    end
  end

  describe "el ciclo" do
    test "nace cerrado, y cuatro cuelgues no lo abren" do
      breaker = Breaker.new()
      assert Breaker.check(breaker, 0) == :closed

      breaker = Enum.reduce(1..4, breaker, fn t, b -> Breaker.record(b, :timeout, t) end)

      assert Breaker.check(breaker, 5) == :closed
    end

    test "el quinto seguido abre, y el enfriamiento no ha pasado" do
      breaker = Enum.reduce(1..5, Breaker.new(), fn t, b -> Breaker.record(b, :timeout, t) end)

      assert Breaker.check(breaker, 100) == :open
      # 29 999 ms después del quinto: todavía no.
      assert Breaker.check(breaker, 5 + 29_999) == :open
    end

    test "pasado el enfriamiento hay sonda" do
      breaker = Enum.reduce(1..5, Breaker.new(), fn t, b -> Breaker.record(b, :timeout, t) end)

      assert Breaker.check(breaker, 5 + 30_000) == :probe
    end

    test "fallos no consecutivos no abren: una vuelta buena resetea" do
      breaker =
        Enum.reduce(1..4, Breaker.new(), fn t, b -> Breaker.record(b, :timeout, t) end)

      breaker = Breaker.record(breaker, :answered, 10)
      breaker = Enum.reduce(11..14, breaker, fn t, b -> Breaker.record(b, :timeout, t) end)

      assert Breaker.check(breaker, 20) == :closed
    end

    test "la sonda que contesta cierra" do
      breaker = Enum.reduce(1..5, Breaker.new(), fn t, b -> Breaker.record(b, :timeout, t) end)
      assert Breaker.check(breaker, 5 + 30_000) == :probe

      breaker = Breaker.record(breaker, :answered, 5 + 30_001)

      assert Breaker.check(breaker, 5 + 30_002) == :closed
    end

    test "la sonda que vuelve a colgarse reabre, y el enfriamiento se reaplaza" do
      breaker = Enum.reduce(1..5, Breaker.new(), fn t, b -> Breaker.record(b, :timeout, t) end)

      # La sonda pasa a los 30 s y se cuelga: el fallo es nuevo y el
      # enfriamiento cuenta desde aquí — si no, la sonda siguiente
      # encontraría el circuito medio abierto para cualquiera que llegue.
      breaker = Breaker.record(breaker, :timeout, 5 + 30_000)

      assert Breaker.check(breaker, 5 + 30_001) == :open
      assert Breaker.check(breaker, 5 + 59_999) == :open
      assert Breaker.check(breaker, 5 + 60_000) == :probe
    end

    test "con umbral 1, el primer cuelgue ya abre" do
      breaker = Breaker.new(breaker_threshold: 1)
      breaker = Breaker.record(breaker, :timeout, 7)

      assert Breaker.check(breaker, 8) == :open
    end
  end

  describe "verdict/1: que cuenta como fallo" do
    test "solo el plazo" do
      assert Breaker.verdict({:error, :timeout, []}) == :timeout
      assert Breaker.verdict({:error, :timeout, [%{step: 1}]}) == :timeout
    end

    test "contestar que no es contestar" do
      # Un error del motor es una respuesta: cierra el circuito, no lo abre.
      assert Breaker.verdict({:error, {:model_not_up, "coder"}, []}) == :answered
      assert Breaker.verdict({:error, :no_backend, []}) == :answered
      assert Breaker.verdict({:ok, "lo que sea", []}) == :answered
    end
  end
end
