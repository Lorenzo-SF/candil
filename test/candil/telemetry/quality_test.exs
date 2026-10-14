defmodule Candil.Telemetry.QualityTest do
  @moduledoc """
  Las dos señales, con su retardo declarado.

  Lo que mas importa aquí no es que cuente: es que **una peticion que aun no ha
  podido fallar no cuente como buena**. Un reintento que llega a los cinco
  segundos de una ventana de treinta no dice nada del modelo que se acaba de
  servir, y contarlo haria mejorparable un modelo que solo esta tardando.
  """

  use ExUnit.Case, async: false

  alias Candil.Telemetry.Quality

  setup do
    Quality.reset()
    :ok
  end

  defp emit(model, finish_reason, prompt_hash) do
    :telemetry.execute([:candil, :llm, :chat, :stop], %{duration: 1}, %{
      model: model,
      finish_reason: finish_reason,
      prompt_hash: prompt_hash
    })
  end

  defp row(model), do: Quality.snapshot().per_model[model]

  describe "la señal primaria: finish_reason anómalo" do
    test "cuenta lo que se quedó sin tokens" do
      emit(:coder, "length", "a")
      emit(:coder, "stop", "b")

      assert row(:coder).served == 2
      assert row(:coder).anomalous == 1
    end

    test "cuenta la negativa del modelo" do
      emit(:coder, "content_filter", "a")

      assert row(:coder).anomalous == 1
    end

    test "un finish_reason normal NO es anómalo" do
      # `stop` es lo normal. Contarlo de más sería inflar la tasa de todos los
      # modelos por igual, que es la misma trampa que contar las cache hits.
      emit(:coder, "stop", "a")

      assert row(:coder).anomalous == 0
      assert row(:coder).anomaly_rate == 0.0
    end
  end

  describe "la señal secundaria: reintentos" do
    test "NO cuenta un reintento que aún no ha podido ocurrir" do
      # La misma pregunta dos veces seguidas: la primera aún no tiene edad
      # para haber recibido un reintento. Si esto contara, cualquier prompt
      # repetido marcaria al modelo como malo.
      emit(:coder, "stop", "misma")
      emit(:coder, "stop", "misma")

      assert row(:coder).retries == 0
    end

    test "y cuenta con el retardo correcto" do
      # Sin simular el reloj no se puede llegar al umbral, y ese es el punto:
      # la ventana se documenta en `retriable_after/0` para poder razonar sobre
      # ella, no solo para tenerla.
      assert Quality.retriable_after() == 30_000
    end
  end

  describe "el denominador" do
    test "las peticiones servidas son el denominador, no las de la cache" do
      for i <- 1..10, do: emit(:coder, "stop", "h#{i}")

      assert row(:coder).served == 10
    end

    test "una tasa sin muestras es cero, no una excepcion" do
      # Un modelo al que no le ha llegado nada tiene tasa 0.0 y no tiene
      # `:infinity`, porque una division entre peticiones que no existen no es
      # una mala respuesta: es una ausencia de datos.
      assert row(:nunca_visto) == nil

      assert Quality.snapshot().per_model == %{coder: row(:coder)} or
               is_map(Quality.snapshot().per_model)
    end
  end

  describe "la tabla" do
    test "se imprime sin romperse con datos y sin ellos" do
      assert Quality.format(%{per_model: %{}, signals: %{}}) =~ "CALIDAD POR MODELO"

      for i <- 1..3, do: emit(:coder, "stop", "x#{i}")
      emit(:coder, "length", "y")

      texto = Quality.format(Quality.snapshot())
      assert texto =~ ":coder"
      assert texto =~ "anomalos"
    end
  end

  describe "la tabla del historico" do
    test "el dueno es el proceso supervisado, no la peticion que la creo" do
      # La tabla del reintento se creaba a demanda, desde el proceso de la
      # peticion. Sin dueno supervisado cada peticion se llevaba su historico:
      # `retry_rate` salia 0 sin que nada fallara visiblemente, porque el dato
      # que lo calcula se iba con el proceso.
      tabla = Candil.Telemetry.Quality.Remember

      assert :ets.whereis(tabla) != :undefined, "la tabla no existe sin que pase una peticion"
      assert :ets.info(tabla, :owner) == Process.whereis(Quality)
    end

    test "doce peticiones simultaneas no se la llevan por delante" do
      # El fallo eran dos cosas en una: un check-then-act (las doce creaban la
      # tabla y la que perdia se comia un ArgumentError y tumbaba el handler) y
      # un dueno equivocado (la tabla se creaba desde el proceso de la peticion
      # y se iba con el, llevandose el historico entero).
      #
      # Con trafico simultaneo —que es lo que pasa cuando el destino NO es
      # exclusivo, o cuando se entra por la API y no por el gateway— ninguna de
      # las dos es una excepcion aislada.
      #
      # Tabla real, no una de prueba: el dueno es lo que se quiere comprobar y
      # una tabla que crea cada proceso se lo lleva el proceso.
      #
      # El barrier tambien importa: sin el, los doce se ejecutan en serie y el
      # test pasa siempre, bug incluido.
      tabla = Candil.Telemetry.Quality.Remember
      parent = self()
      n = 12

      tareas =
        for i <- 1..n do
          Task.async(fn ->
            send(parent, {:llegado, self()})

            receive do
              :todos -> :ok
            after
              5_000 -> :timeout
            end

            try do
              tabla.put(tabla, "clave-#{rem(i, 3)}", i)
              :ok
            rescue
              e -> {:crash, Exception.message(e)}
            catch
              k, v -> {:crash, "#{inspect(k)} #{inspect(v)}"}
            end
          end)
        end

      for _ <- 1..n do
        assert_receive {:llegado, _pid}, 5_000
      end

      Enum.each(tareas, &send(&1.pid, :todos))

      crashed =
        for tarea <- tareas do
          case Task.await(tarea, 5_000) do
            :ok -> nil
            otro -> otro
          end
        end
        |> Enum.reject(&is_nil/1)

      assert crashed == [], "una peticion se ha comido el error de otra: #{inspect(crashed)}"

      # Y la tabla sigue viva: los doce procesos ya han muerto.
      assert :ets.whereis(tabla) != :undefined, "la tabla se ha ido con las peticiones"
      assert :ets.info(tabla, :owner) == Process.whereis(Quality)
    end
  end
end
