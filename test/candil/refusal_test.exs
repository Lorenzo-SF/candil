defmodule Candil.RefusalTest do
  @moduledoc """
  La politica de «nadie contesta», con **los numeros** y no con frases.

  Cada numero viene de una medicion y el test la nombra, para que cambiarlo
  sea una decision visible y no un numero que aparecio un dia.
  """

  use ExUnit.Case, async: true

  alias Candil.Refusal

  describe "los numeros por defecto" do
    test "son los que salio de la ronda del consultor, y estan medidos" do
      # wait: dos veces el peor caso medido (28 s de espera mediana con los
      # turnos puestos), porque por debajo de 30 s cortas peticiones que iban a
      # resolverse y por encima de 120 s nadie espera sin saber por que.
      assert Refusal.defaults()[:wait_timeout_ms] == 60_000

      # El tope global es un override, no la politica base.
      assert Refusal.defaults()[:global_wait_timeout_ms] == nil

      assert Refusal.defaults()[:retry_after_ms] == 30_000
    end

    test "el defecto es :fail, NO :wait, y esta medido" do
      # El consultor propuso `wait`. Medido el 2026-10-14 sobre la suite del
      # router, con un solo caso de «no hay modelos»:
      #
      #     wait  ->  la suite tardaba 60,3 s
      #     fail  ->  la suite tardaba  0,3 s
      #
      # Doscientas veces, y no porque `wait` tarde: porque con el defecto
      # equivocado un «no hay modelos» —un error de configuracion— se
      # convierte en un minuto de cuelgue sin arreglar nada.
      assert Refusal.defaults()[:strategy] == :fail
    end
  end

  describe "el tope de espera de un destino" do
    test "es 60 s cuando el destino no declara nada" do
      assert Refusal.wait_timeout_ms(%{}) == 60_000
      assert Refusal.wait_timeout_ms(nil) == 60_000
    end

    test "un destino lento declara cuanto se demora y gana a la constante" do
      # Un 60 s fijo cortaria un modelo de CPU que tarda 120 s. Un destino lento
      # con un wait lento **y solo suyo**: uno rapido no espera por su culpa.
      lento = %{typical_latency_s: 120}

      assert Refusal.wait_timeout_ms(lento) == 240_000
    end

    test "un destino rapio no baja del suelo" do
      # `max` y no sustitucion: declarar «soy rapido» no puede hacer que el wait
      # sea de 200 ms cuando el suelo son 60.
      rapido = %{typical_latency_s: 5}

      assert Refusal.wait_timeout_ms(rapido) == 60_000
    end

    test "un valor sin sentido no mueve nada" do
      for malo <- [0, -5, :no, nil] do
        assert Refusal.wait_timeout_ms(%{typical_latency_s: malo}) == 60_000
      end
    end
  end

  describe "el Retry-After" do
    test "es la mitad del tope cuando el tope es pequeno" do
      # El invariante del consultor: `Retry-After <= wait_timeout`. Un cliente
      # que cumple lo que le dicen no se encuentra esperando el timeout entero
      # otra vez.
      assert Refusal.retry_after_ms(30_000) == 15_000
      assert Refusal.retry_after_ms(20_000) == 10_000
    end

    test "es 30 s cuando el tope es grande" do
      assert Refusal.retry_after_ms(60_000) == 30_000
      assert Refusal.retry_after_ms(240_000) == 30_000
    end

    test "y nunca supera el tope que se esta aplicando" do
      for timeout <- [1_000, 5_000, 60_000, 240_000] do
        assert Refusal.retry_after_ms(timeout) <= timeout
      end
    end
  end

  describe "que errores son de refusal" do
    test "los tres que son 'no hay quien conteste'" do
      assert Refusal.refusal_error?(:no_models_for_consumer)
      assert Refusal.refusal_error?(:all_candidates_vetoed)
      assert Refusal.refusal_error?(:insufficient_capacity)
    end

    test "y un fallo de configuracion no se disfraza de capacidad" do
      # Esperar no arregla un `model_not_found`. Tratarlo como refusal seria
      # esconder un error de configuracion detras de un 503 con reintento.
      refute Refusal.refusal_error?(:model_not_found)
      refute Refusal.refusal_error?(:engine_not_running)
      refute Refusal.refusal_error?({:error, :no_classifier_model, :a})
    end
  end

  describe "el error que ve el cliente" do
    test "lleva el motivo de origen y el retry_after" do
      error = Refusal.error(:all_candidates_vetoed, 30_000)

      assert error.reason == :no_capacity
      assert error.context.reason_origen == :all_candidates_vetoed
      assert error.context.retry_after == 30_000
    end

    test "y el mensaje dice el motivo y el numero, sin unidades ambiguas" do
      error = Refusal.error(:no_models_for_consumer, 30_000)

      assert error.context.message =~ ":no_models_for_consumer"
      assert error.context.message =~ "30 s"
    end
  end

  describe ":degrade no esta, y por que" do
    # El *por que* va en el `@moduledoc` y no se comprueba aqui: un test que
    # lee un comentario falla cuando le reescribes el comentario, que no es lo
    # que importa. Lo que si se comprueba es la **forma**, que es un hecho.
    test "el modulo no exporta ninguna funcion que degrade" do
      # Degradar es servir con otro modelo que cubra lo mismo, y para saber si
      # otro cubre lo mismo hay que saber que pide la pregunta. Sin el
      # enrutado por capacidad, `degrade` seria adivinar.
      refute function_exported?(Refusal, :degrade, 2)
      refute function_exported?(Refusal, :degrade, 3)
      refute function_exported?(Refusal, :degrade, 1)
    end

    test "las estrategias que anuncia son solo dos" do
      # Si alguien anade `:degrade` a los defaults sin el enrutado por
      # cobertura, este test falla.
      estrategias = Refusal.defaults() |> Keyword.get(:strategy)
      refute estrategias == :degrade

      assert Refusal.defaults()[:strategy] in [:fail, :wait]
    end

    test "escribirlo en la configuracion revienta diciendo que falta, no «desconocida»" do
      # El nombre esta bien y la estrategia esta declarada; lo que falta es el
      # enrutado por cobertura. Un raise que dijera «desconocida» mandaria a
      # quien lo lee a buscar una errata que no existe.
      assert_raise ArgumentError, ~r/enrutado por cobertura/, fn ->
        Refusal.apply(
          [%{role: "user", content: "hola"}],
          :default,
          [strategy: :degrade],
          fn -> {:error, :no_models_for_consumer} end,
          :no_models_for_consumer
        )
      end
    end
  end
end
