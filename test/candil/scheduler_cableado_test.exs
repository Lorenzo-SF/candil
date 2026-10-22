defmodule Candil.Scheduler.CableadoTest do
  @moduledoc """
  Pruebas de que el scheduler está cableado de verdad: `ensure_engine_running/2`
  consulta a `Scheduler.plan/1`.

  Sin estas, borrar el cableado deja la suite verde (D-10).

  El binario y el modelo **no existen a propósito**: el rechazo ocurre antes de
  tocar el fichero. Si alguien cambia el orden y el arranque falla por «binary
  not found», la aserción se pone roja —que es lo que se quiere.

  ## La GPU es de mentira

  El scheduler decide sobre devices reales, y una máquina sin GPU daría
  `{:error, :no_gpu}` en vez de `{:error, :no_room}`: dos hechos distintos que
  el mensaje distingue. Con un `nvidia-smi` de mentira (`Candil.FakeGPU`) los
  dos casos se prueban en cualquier sitio, y el resultado no depende de la
  máquina.
  """

  use ExUnit.Case, async: false

  alias Candil.{FakeGPU, Model, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Candil.StoreCase.empty_store()
    on_exit(fn -> Candil.StoreCase.empty_store() end)

    FakeGPU.install(tmp_dir, total_mb: 16_303, free_mb: 16_000)
    on_exit(&FakeGPU.uninstall/0)
    on_exit(fn -> Candil.Engine.Resource.stop_device(0) end)

    :ok
  end

  test "un modelo que no cabe devuelve :no_room (cableado)" do
    engine = %Candil.Engine{
      alias: :llama_cpp,
      binary: "/nonexistent/llama-server",
      host: "127.0.0.1",
      port: 9991
    }

    Candil.Store.register_engine(engine)

    model = %Model{
      alias: :huge_test,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      vram_mb: 999_999,
      usage: [:chat],
      model_dir: "/nonexistent",
      filename: "huge.gguf"
    }

    Store.register_model(model)

    assert {:error, :no_room} = Candil.ensure_engine_running(:huge_test, [])
  end

  describe "sin GPU" do
    setup %{tmp_dir: tmp_dir} do
      # Ahora sí, una máquina sin GPU: el `nvidia-smi` de mentira falla, que es
      # lo que ve una máquina sin NVIDIA.
      FakeGPU.install(tmp_dir, no_gpu: true)
      :ok
    end

    test "un modelo de GPU devuelve :no_gpu, que no es :no_room" do
      # «Esta máquina no tiene GPU» y «no cabe» son hechos distintos, y el
      # mensaje tiene que distinguirlos: el primero tiene salida (`--cpu`) y
      # el segundo no. Con un solo error, en una máquina sin GPU se decía
      # «la GPU está llena».
      engine = %Candil.Engine{
        alias: :llama_cpp,
        binary: "/nonexistent/llama-server",
        host: "127.0.0.1",
        port: 9991
      }

      Candil.Store.register_engine(engine)

      model = %Model{
        alias: :gpu_model,
        type: :local,
        engine: :llama_cpp,
        context_size: 4096,
        usage: [:chat],
        model_dir: "/nonexistent",
        filename: "model.gguf"
      }

      Store.register_model(model)

      assert {:error, :no_gpu} = Candil.ensure_engine_running(:gpu_model, [])
    end

    test "un modelo de CPU arranca igual: no pide GPU" do
      # Lo contrario del caso anterior: un modelo que corre en CPU **no puede
      # quedarse sin arrancar por falta de GPU**. Con `gpu_layers: 0` el
      # scheduler no se consulta siquiera.
      engine = %Candil.Engine{
        alias: :llama_cpp,
        binary: "/nonexistent/llama-server",
        host: "127.0.0.1",
        port: 9991
      }

      Candil.Store.register_engine(engine)

      model = %Model{
        alias: :cpu_model,
        type: :local,
        engine: :llama_cpp,
        context_size: 4096,
        gpu_layers: 0,
        usage: [:chat],
        model_dir: "/nonexistent",
        filename: "model.gguf"
      }

      Store.register_model(model)

      # El error NO es `:no_gpu`: es el de verdad, que es que el binario no
      # existe. Lo que se comprueba es que no se rechazó por falta de GPU.
      assert {:error, :no_gpu} != Candil.ensure_engine_running(:cpu_model, [])
    end
  end
end
