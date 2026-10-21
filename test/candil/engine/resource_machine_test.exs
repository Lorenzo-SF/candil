defmodule Candil.Engine.Resource.MachineTest do
  use ExUnit.Case, async: false

  alias Candil.{Engine, Model, Store}

  @binary System.get_env("CANDIL_TEST_LLAMA_SERVER")
  @model System.get_env("CANDIL_TEST_GGUF")

  @machine? is_binary(@binary) and is_binary(@model)

  if not @machine? do
    @moduletag :skip
  end

  setup do
    previous_adapter = Application.get_env(:apero, :http_adapter)
    Application.put_env(:apero, :http_adapter, Apero.Http.Adapter.Finch)

    # El device tiene que estar registrado ANTES de medir: `available/1` de un
    # device sin registrar devuelve 0, y comparar contra ese 0 haría pasar el
    # test sin haber reservado nada.
    :ok = Candil.Engine.Resource.ensure_registered(0)

    on_exit(fn ->
      Application.put_env(:apero, :http_adapter, previous_adapter)

      for model_alias <- [:oom_test_model, :missing_binary_model, :recorte_test_model] do
        try do
          Candil.Llm.stop_engine(model_alias)
        rescue
          _ -> :ok
        end

        try do
          Store.deregister_model(model_alias)
        rescue
          _ -> :ok
        end
      end

      for engine_alias <- [:llama_cpp, :missing_binary_llama_cpp] do
        try do
          Store.deregister_engine(engine_alias)
        rescue
          _ -> :ok
        end
      end
    end)

    engine = %Engine{
      alias: :llama_cpp,
      binary: @binary,
      host: "127.0.0.1",
      port: 9994
    }

    :ok = Store.register_engine(engine)
    :ok
  end

  # La sonda de salud del motor: `Engine.healthy?/1` consulta al server por
  # HTTP, y el server no responde hasta que ha cargado el modelo. Es la
  # prueba de que los args sirvieron.
  defp eventually_healthy(alias_, tries \\ 120) do
    cond do
      Candil.Llm.engine_healthy?(alias_) -> true
      tries == 0 -> false
      true -> Process.sleep(1_000) && eventually_healthy(alias_, tries - 1)
    end
  end

  test "un arranque fallido antes de crear el server libera la reserva" do
    engine = %Engine{
      alias: :missing_binary_llama_cpp,
      binary: "/nonexistent/candil-does-not-ship-llama-server",
      host: "127.0.0.1",
      port: 9996
    }

    :ok = Store.register_engine(engine)

    model = %Model{
      alias: :missing_binary_model,
      type: :local,
      engine: :missing_binary_llama_cpp,
      context_size: 4096,
      vram_mb: 32,
      usage: [:chat],
      model_dir: "/nonexistent",
      filename: "no_such_model.gguf",
      gpu_layers: 99
    }

    :ok = Store.register_model(model)

    available_before = Candil.Engine.Resource.available(0)

    assert {:error, _} =
             Candil.Llm.start_engine(:missing_binary_llama_cpp, :missing_binary_model, 0)

    assert Candil.Engine.Resource.available(0) == available_before,
           "la reserva no se liberó: antes=#{available_before}, después=" <>
             "#{Candil.Engine.Resource.available(0)}"
  end

  @tag timeout: 300_000
  test "un modelo real que NECESITA RECORTE arranca, y su peso es el ajustado" do
    # La puerta que faltaba. Los dos fallos de `FitParams` —el peso
    # proyectado en vez del ajustado, y el `-ot` entrecomillado— SOLO se ven
    # con un modelo que necesita recorte, porque son los únicos casos en los
    # que `fit-params` escribe un `-ot` y en los que el peso ajustado es
    # menor que el proyectado.
    #
    # Con un modelo que cabe entero no hay recorte, no hay `-ot`, y el peso
    # proyectado y el ajustado coinciden. Por eso el gate anterior, con un
    # modelo de 4 GB, no cazó nada.
    model = %Model{
      alias: :recorte_test_model,
      type: :local,
      engine: :llama_cpp,
      context_size: 131_072,
      usage: [:chat],
      model_dir: Path.dirname(@model),
      filename: Path.basename(@model),
      gpu_layers: -1,
      model_args: ["--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--kv-unified"]
    }

    :ok = Store.register_model(model)

    # 1 · El peso ajustado cabe en la memoria libre REAL, y es el ajustado.
    [device] = Candil.Scheduler.Devices.detect()

    assert {:ok, weight, args} =
             Candil.Engine.FitParams.run(elem(Store.get_engine(:llama_cpp), 1), model, 0)

    assert weight > 0, "el peso ajustado es 0"

    # El peso ajustado tiene que caber en la GPU **entera**, y no en la
    # memoria libre del instante: esa la mide otra sesión y cambia mientras
    # se mide (el 2026-10-21, con otra sesión moviéndose, el peso medido fue
    # de 556 MiB con 441 MiB libres — porque la memoria libre cayó entre la
    # lectura y la medición).
    #
    # Y lo que esta aserción caza es el bug de verdad: el peso **proyectado**
    # (19053 MiB) no cabe en 16303 MiB de GPU, así que con el parser viejo
    # —que leía el proyectado— esta puerta se ponía roja. Y con el peso
    # proyectado, además, la reserva de 19053 contra una capacidad de 16303
    # no habría cabido: el modelo no habría arrancado.
    assert weight < device.total_mb,
           "el peso (#{weight}) no cabe en los #{device.total_mb} MiB de la GPU: " <>
             "eso es el peso PROYECTADO, no el ajustado"

    # Y los args no llevan comillas: con ellas, llama-server responde
    # `unknown buffer type` y NO ARRANCA.
    refute Enum.any?(args, &String.contains?(&1, "\""))

    # 2 · El motor arranca de verdad, y por el camino **ÚNICO**: el scheduler
    # decide el device y la reserva va antes de arrancar.
    #
    # Esto es, a la vez, la prueba de que `place/3` **se ejecutó**. `Engine.start/3`
    # con `device = nil` no reserva nada —sin device no hay dónde reservar—, así
    # que **que haya reserva** prueba que alguien decidió un device. Y el único
    # que decide es `Scheduler.plan/1`. Un test que solo comprueba que la
    # función tiene tests no prueba nada de esto.
    #
    # El ledger se reajusta antes de medir, porque `start_placed` sincroniza la
    # memoria ajena y eso cambia la disponible.
    :ok = Candil.Engine.Resource.sync_foreign(0)
    available_before = Candil.Engine.Resource.available(0)
    engine = elem(Store.get_engine(:llama_cpp), 1)

    assert {:ok, _pid} = Candil.Engine.start_placed(engine, model)

    # 3 · La reserva es el peso real, no el declarado.
    assert Candil.Engine.Resource.available(0) == available_before - weight

    # 3-bis · Y el motor CARGA de verdad. Con los args rotos —el `-ot` entrecomillado—
    # llama-server responde `unknown buffer type` y sale; con el peso
    # proyectado en vez del ajustado, hace OOM. Los dos fallos.medidos pasaban
    # el `{:ok, pid}` y morian despues, asi que sin esta espera el test pasa
    # con el motor muerto.
    assert eventually_healthy(:recorte_test_model),
           "el motor no llegó a estar sano: el log dice lo que pasó"

    # 4 · Y al parar, la memoria vuelve.
    :ok = Candil.Llm.stop_engine(:recorte_test_model)

    assert Candil.Engine.Resource.available(0) == available_before
  end

  test "un motor que muere después de arrancar libera la reserva" do
    # El server está linkado al proceso que lo arranca, como cualquier
    # `start_link`: si el motor cae, el padre recibe la salida. Aquí se
    # atrapa para poder comprobar la reserva después de la caída.
    Process.flag(:trap_exit, true)

    # El GGUF no existe: el binario arranca y sale con error. Es el camino de
    # un OOM —el server existe, el motor cae— sin gastar 15 GB de VRAM.
    model = %Model{
      alias: :oom_test_model,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      vram_mb: 32,
      usage: [:chat],
      model_dir: "/nonexistent",
      filename: "no_such_model.gguf",
      gpu_layers: 99
    }

    :ok = Store.register_model(model)

    available_before = Candil.Engine.Resource.available(0)

    assert {:ok, pid} = Candil.Llm.start_engine(:llama_cpp, :oom_test_model, 0)

    assert Candil.Engine.Resource.available(0) == available_before - 32

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000

    assert Candil.Engine.Resource.available(0) == available_before,
           "la reserva no se liberó: antes=#{available_before}, después=" <>
             "#{Candil.Engine.Resource.available(0)}"
  end
end
