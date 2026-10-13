defmodule Candil.Telemetry.DecisionsTest do
  @moduledoc """
  El contador del tribunal, y sobre todo **que cuenta peticiones y no capas**.

  El bug que este modulo evita no se ve en los numeros: se ve en el denominador.
  Si el evento se emitiera por capa, tres capas ejecutadas en una peticion
  darian tres eventos, el total triplicado, y el porcentaje de LLM mas bajo de
  lo que es. No un numero grande — **otro numero**.

  Y la trampa hermana, que el modulo expone por diseno: `llm_called` va aparte
  de `strategy`. El clasificador puede ejecutarse, pagar su inferencia y no
  pasar el umbral; la decision es `:default` con el LLM ya cobrado, y un
  contador que mirara solo la estrategia diria que no se llamo nunca.
  """

  use ExUnit.Case, async: false

  alias Candil.Telemetry.Decisions

  setup do
    Decisions.reset()
    :ok
  end

  defp decision(strategy, llm_called) do
    :telemetry.execute([:candil, :router, :decision], %{duration: 1}, %{
      strategy: strategy,
      llm_called: llm_called
    })
  end

  describe "contar" do
    test "una peticion, un evento" do
      decision(:rule, false)
      assert Decisions.snapshot().total == 1
    end

    test "cada capa por separado" do
      decision(:rule, false)
      decision(:llm, true)
      decision(:embedding, false)

      s = Decisions.snapshot()
      assert s.total == 3
      assert s.by_strategy == %{rule: 1, llm: 1, embedding: 1}
    end
  end

  describe "la trampa: el LLM puede correr y no ganar" do
    test "strategy dice default pero llm_called dice que si" do
      # El clasificador se ejecuta, paga su inferencia, y su confianza no pasa
      # el umbral. La decision es `:default`. Mirar solo `strategy` diria que el
      # LLM no intervino: es la mentira que lo hace caro.
      decision(:default, true)

      s = Decisions.snapshot()
      assert s.by_strategy == %{default: 1}
      assert s.llm_called == 1
    end

    test "y los dos se suman sin contarse dos veces" do
      decision(:llm, true)
      decision(:default, true)

      s = Decisions.snapshot()
      assert s.total == 2
      assert s.llm_called == 2
      # El total NO es `by_strategy` + `llm_called`: son dos vistas de lo mismo.
      assert s.tribunal.static == 0
      assert s.tribunal.llm_pct == 100.0
    end
  end

  describe "el tribunal" do
    test "sin decisiones, el mapa trae las claves y no un holes" do
      s = Decisions.snapshot()

      assert s.total == 0
      assert s.by_strategy == %{}
      assert s.llm_called == 0
      # La clave que un lector hace `tribunal.static` tiene que existir desde el
      # primer segundo, no aparecer en la primera peticion.
      assert s.tribunal.static == 0
      assert s.tribunal.llm_pct == 0.0
      assert s.tribunal.verdict == "sin datos"
    end

    test "siete de cada diez por la politica estatica" do
      for _ <- 1..7, do: decision(:rule, false)
      for _ <- 1..3, do: decision(:llm, true)

      s = Decisions.snapshot()
      assert s.total == 10
      assert s.tribunal.static == 7
      assert s.tribunal.llm_pct == 30.0
      assert s.tribunal.static_pct == 70.0
    end

    test "el veredicto avisa cuando hay que arreglar las senales" do
      for _ <- 1..8, do: decision(:llm, true)

      assert Decisions.snapshot().tribunal.verdict =~ "ARREGLAR LAS SENALES"
    end

    test "y se calma cuando el LLM es ruido" do
      for _ <- 1..19, do: decision(:rule, false)
      decision(:llm, true)

      assert Decisions.snapshot().tribunal.verdict =~ "aguanta"
    end
  end

  describe "reset" do
    test "pone a cero sin perder la forma" do
      decision(:rule, false)
      assert Decisions.reset() == :ok

      s = Decisions.snapshot()
      assert s.total == 0
      assert s.by_strategy == %{}
      assert s.tribunal.static == 0
    end
  end

  describe "format" do
    test "es texto, y el texto va en otra capa" do
      decision(:rule, false)

      texto = Decisions.format(Decisions.snapshot())
      assert texto =~ "DECISIONES DEL ROUTER"
      assert texto =~ ":rule"
      # El tribunal se ve sin tener que hacer aritmetica a mano, que es lo
      # unico que se le pide a una pantalla.
      assert texto =~ "60%"
    end
  end
end
