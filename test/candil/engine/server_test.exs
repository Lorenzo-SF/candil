defmodule Candil.Engine.ServerTest do
  @moduledoc """
  Los argumentos del motor, y en particular el **device**.

  Desde D-28 el `--device` no es `CUDA\#{índice}`: es el **nombre que publica el
  motor** (`CUDA0`, `ROCm0`, `Vulkan0`…). `CUDA\#{índice}` era la convención de
  CUDA y es falsa en los otros backends, donde el motor la rechaza con
  `invalid device`.
  """

  use ExUnit.Case, async: true

  alias Candil.{Engine, Model}
  alias Candil.FakeGPU

  @moduletag :tmp_dir

  defp engine(binary, cpu \\ false) do
    %Engine{
      alias: :llama_cpp,
      binary: binary,
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

  # Un motor de mentira que publica su lista de devices. No toca el `PATH`:
  # se usa por ruta absoluta, así que el test puede ser `async`.
  defp fake_engine(tmp_dir, devices) do
    FakeGPU.install_engine(tmp_dir, devices: devices)
  end

  defp cuda(index, total \\ 15_933, free \\ 15_000) do
    %{name: "CUDA#{index}", total_mb: total, free_mb: free}
  end

  describe "args_for/4" do
    test "el device es el NOMBRE que publica el motor", %{tmp_dir: tmp_dir} do
      binary = fake_engine(tmp_dir, [cuda(0)])

      args = Candil.Engine.Server.args_for(engine(binary), model(), 0, nil)

      assert "--device" in args
      assert "CUDA0" in args
      assert "--split-mode" in args
      assert "none" in args
      assert "--main-gpu" in args
      assert "0" in args
    end

    test "el nombre no se deriva del índice: en ROCm no es CUDA", %{tmp_dir: tmp_dir} do
      binary =
        fake_engine(tmp_dir, [
          %{name: "ROCm0", total_mb: 15_933, free_mb: 15_000},
          %{name: "ROCm1", total_mb: 15_933, free_mb: 15_000}
        ])

      args = Candil.Engine.Server.args_for(engine(binary), model(), 1, nil)

      assert "ROCm1" in args
      refute "CUDA1" in args
    end

    test "el índice del motor es la posición en su lista", %{tmp_dir: tmp_dir} do
      binary =
        fake_engine(tmp_dir, [
          cuda(0),
          %{name: "Vulkan0", total_mb: 15_933, free_mb: 15_000}
        ])

      args = Candil.Engine.Server.args_for(engine(binary), model(), 1, nil)

      assert "Vulkan0" in args
      assert "1" in args
    end

    test "CPU (--cpu) pasa --device none y no pasa --main-gpu", %{tmp_dir: tmp_dir} do
      binary = fake_engine(tmp_dir, [cuda(0)])

      args = Candil.Engine.Server.args_for(engine(binary, true), model(), 0, nil)

      assert "none" in args
      refute "--main-gpu" in args
      refute "--split-mode" in args
    end

    test "gpu_layers 0 pasa --device none aunque no sea --cpu", %{tmp_dir: tmp_dir} do
      binary = fake_engine(tmp_dir, [cuda(0)])

      args = Candil.Engine.Server.args_for(engine(binary), model(0), 0, nil)

      assert "none" in args
      refute "--main-gpu" in args
    end

    test "sin device (nil) no pasa flags de device", %{tmp_dir: tmp_dir} do
      binary = fake_engine(tmp_dir, [cuda(0)])

      args = Candil.Engine.Server.args_for(engine(binary), model(), nil, nil)

      refute "--device" in args
      refute "--split-mode" in args
      refute "--main-gpu" in args
    end

    test "sin el motor no se inventa el nombre del device", %{tmp_dir: tmp_dir} do
      # Sin motor no hay nombre, y `--device` no acepta índices. Antes se
      # escribía `CUDA0` a ojo; ahora se dice que no se sabe.
      assert_raise ArgumentError, fn ->
        Candil.Engine.Server.args_for(
          engine(Path.join(tmp_dir, "no-existe-llama-server")),
          model(),
          0,
          nil
        )
      end
    end

    test "path traversal sigue levantando", %{tmp_dir: tmp_dir} do
      binary = fake_engine(tmp_dir, [cuda(0)])
      bad = %{model() | model_dir: "/tmp/../etc"}

      assert_raise ArgumentError, fn ->
        Candil.Engine.Server.args_for(engine(binary), bad, 0, nil)
      end
    end
  end
end
