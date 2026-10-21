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

      for model_alias <- [:oom_test_model, :missing_binary_model] do
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
