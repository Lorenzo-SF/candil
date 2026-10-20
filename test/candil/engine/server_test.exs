defmodule Candil.Engine.ServerTest do
  use ExUnit.Case, async: true

  alias Candil.{Engine, Model}

  defp engine(cpu \\ false) do
    %Engine{
      alias: :llama_cpp,
      binary: "/nonexistent/llama-server",
      host: "127.0.0.1",
      port: 9991,
      cpu: cpu,
      start_args: []
    }
  end

  defp model(gpu_layers \\ 99) do
    %Model{
      alias: :test_model,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      gpu_layers: gpu_layers,
      model_dir: "/tmp",
      filename: "test.gguf"
    }
  end

  describe "args_for/3" do
    test "GPU con device entero pasa --device CUDA<N> --split-mode none --main-gpu N" do
      args = Candil.Engine.Server.args_for(engine(), model(), 0, nil)
      assert "--device" in args
      assert "CUDA0" in args
      assert "--split-mode" in args
      assert "none" in args
      assert "--main-gpu" in args
      assert "0" in args
    end

    test "GPU con device 1 traduce a CUDA1" do
      args = Candil.Engine.Server.args_for(engine(), model(), 1, nil)
      assert "CUDA1" in args
      assert "1" in args
    end

    test "CPU (--cpu) pasa --device none y no pasa --main-gpu" do
      args = Candil.Engine.Server.args_for(engine(true), model(), 0, nil)
      assert "none" in args
      refute "--main-gpu" in args
      refute "--split-mode" in args
    end

    test "gpu_layers 0 pasa --device none aunque no sea --cpu" do
      args = Candil.Engine.Server.args_for(engine(), model(0), 0, nil)
      assert "none" in args
      refute "--main-gpu" in args
    end

    test "sin device (nil) no pasa flags de device" do
      args = Candil.Engine.Server.args_for(engine(), model(), nil, nil)
      refute "--device" in args
      refute "--split-mode" in args
      refute "--main-gpu" in args
    end

    test "path traversal sigue levantando" do
      bad = %{model() | model_dir: "/tmp/../etc"}

      assert_raise ArgumentError, fn ->
        Candil.Engine.Server.args_for(engine(), bad, 0, nil)
      end
    end
  end
end
