defmodule Candil.Router.FallbackTest do
  @moduledoc """
  Que pasa cuando **ninguna capa sabe** — que, medido, es lo que pasa en 88% de
  las peticiones reales.

  Y el punto de todo este fichero: **eso no es el residual, es el grueso**. Lo
  que hay por debajo del enrutado estaba escrito como `List.last(candidates)`,
  una linea, y decide mas veces que todas las capas juntas.
  """

  use ExUnit.Case, async: false

  alias Candil.Router.Fallback

  @tres [:uno, :dos, :tres]

  setup do
    Fallback.reset()
    :ok
  end

  describe "elegir desde el toml" do
    test "sin [router] fallback, es :last — lo que habia siempre" do
      assert Fallback.configured(%{}) == :last
      assert Fallback.configured(nil) == :last
    end

    test "una estrategia del toml llega" do
      assert Fallback.configured(%{fallback: "round_robin"}) == :round_robin
      assert Fallback.configured(%{fallback: :least_used}) == :least_used
    end

    test "y una mal escrita NO revienta el router" do
      # Un nombre mal escrito es un nombre mal escrito. Reventar el enrutado
      # entero porque alguien escribio "roundrobin" sin guion deja sin servicio
      # a quien solo queria una lista.
      assert Fallback.configured(%{fallback: "roundrobin"}) == :last
      assert Fallback.configured(%{fallback: "no existe"}) == :last
      assert Fallback.configured(%{fallback: 42}) == :last
    end
  end

  describe "last y first" do
    test "last es el ultimo, y sigue siendo el defecto" do
      assert {:ok, :tres} = Fallback.pick(:last, @tres, :c)
    end

    test "first es el primero" do
      assert {:ok, :uno} = Fallback.pick(:first, @tres, :c)
    end
  end

  describe "round_robin" do
    test "va dando vueltas en vez de machacar siempre el mismo" do
      picks =
        for _ <- 1..6 do
          {:ok, elegido} = Fallback.pick(:round_robin, @tres, :c)
          elegido
        end

      # Lo que NO es: siempre el mismo. Lo que es: los tres aparecen.
      assert picks == [:uno, :dos, :tres, :uno, :dos, :tres]
      assert length(Enum.uniq(picks)) == 3
    end

    test "el turno es POR CONSUMER" do
      # Dos consumers con la misma lista no son el mismo reparto.
      {:ok, a1} = Fallback.pick(:round_robin, @tres, :consumidor_a)
      {:ok, b1} = Fallback.pick(:round_robin, @tres, :consumidor_b)
      {:ok, a2} = Fallback.pick(:round_robin, @tres, :consumidor_a)

      assert a1 == :uno
      assert b1 == :uno
      assert a2 == :dos
    end
  end

  describe "least_used" do
    test "el primero gana por ser el que menos ha ido" do
      assert {:ok, :uno} = Fallback.pick(:least_used, @tres, :c)
    end

    test "y el turno lo van cambiando, reparte de verdad" do
      picks =
        for _ <- 1..6 do
          {:ok, e} = Fallback.pick(:least_used, @tres, :c)
          e
        end

      assert Enum.uniq(picks) |> length() == 3
    end

    test "empieza igual para todos y por eso el desempate es la posicion" do
      # Al principio todos valen cero. Sin un desempate estable, dos candidatos
      # empatados cambiarian de ganador entre llamadas y el test no podria
      # afirmar nada.
      assert {:ok, :uno} = Fallback.pick(:least_used, @tres, :c1)
      assert {:ok, :uno} = Fallback.pick(:least_used, @tres, :c2)
    end

    test "el contador se lleva solo al que le toco" do
      {:ok, _} = Fallback.pick(:least_used, @tres, :c)
      # El segundo turno tiene que irse a otro: si se quedara en :uno, el
      # contador no estaria contando.
      {:ok, segundo} = Fallback.pick(:least_used, @tres, :c)
      refute segundo == :uno
    end
  end

  describe "sin candidatos" do
    test "no hay a quien elegir, y se dice" do
      assert Fallback.pick(:last, [], :c) == {:error, :no_candidates}
      assert Fallback.pick(:round_robin, [], :c) == {:error, :no_candidates}
    end
  end
end
