defmodule Candil.Engine.FitParams.MachineTest do
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

    on_exit(fn ->
      Application.put_env(:apero, :http_adapter, previous_adapter)

      try do
        Candil.Llm.stop_engine(:fit_weight_test)
      rescue
        _ -> :ok
      end

      try do
        Store.deregister_model(:fit_weight_test)
      rescue
        _ -> :ok
      end

      try do
        Store.deregister_engine(:llama_cpp)
      rescue
        _ -> :ok
      end
    end)

    engine = %Engine{
      alias: :llama_cpp,
      binary: @binary,
      host: "127.0.0.1",
      port: 9992
    }

    :ok = Store.register_engine(engine)
    :ok
  end

  test "el peso calculado coincide con la VRAM medida" do
    model = %Model{
      alias: :fit_weight_test,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      vram_mb: 0,
      usage: [:chat],
      model_dir: Path.dirname(@model),
      filename: Path.basename(@model),
      gpu_layers: -1
    }

    :ok = Store.register_model(model)

    {:ok, weight, _fitted} =
      Candil.Engine.FitParams.run(
        %Engine{
          alias: :llama_cpp,
          binary: @binary,
          host: "127.0.0.1",
          port: 9992,
          cpu: false,
          start_args: []
        },
        model,
        0
      )

    {:ok, _pid} = Candil.Llm.start_engine(:llama_cpp, :fit_weight_test)
    Process.sleep(8_000)
    assert Candil.Llm.engine_healthy?(:fit_weight_test)

    entry = Enum.find(Candil.EnginePool.list(), &(&1.alias == :fit_weight_test))
    assert entry != nil
    os_pid = Candil.Engine.os_pid(entry.pid)
    assert is_integer(os_pid)

    {:ok, processes} = Candil.Detector.Devices.processes()
    measured = Enum.find_value(processes, fn p -> if p.pid == os_pid, do: p.used_mb end)
    assert is_integer(measured) and measured > 0

    ratio = weight / measured

    assert ratio > 0.8 and ratio < 1.2,
           "peso calculado=#{weight} MiB, medido=#{measured} MiB (ratio=#{Float.round(ratio, 2)})"
  end
end
