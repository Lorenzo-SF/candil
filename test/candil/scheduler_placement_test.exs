defmodule Candil.Scheduler.PlacementTest do
  @moduledoc """
  Tres cosas que la colocación tiene que cumplir, y que se pueden comprobar
  sin GPU:

  1. **Un modelo que fija las capas en GPU no se puede ajustar.** Sin
     medición no hay peso real, la reserva se queda en una suposición y el
     motor arranca a ciegas. Se rechaza con `:gpu_layers_fixed`, y la
     excepción son los modelos que reparten los expertos a la CPU
     (`--n-cpu-moe`): esos caben aunque las capas estén fijadas.

  2. **El tamaño de una instancia que ya corre es el que dice `nvidia-smi`.**
     El scheduler expulsa a las víctimas por tamaño, así que con la cuenta
     equivocada dice «no cabe» con la GPU llena de un modelo que sí cabría.
     Medido el 2026-10-22: un `coder` ocupando 1054 MiB de verdad contaba
     como 512 (la estimación).

  3. **Decidir y reservar son una sola operación.** Dos colocaciones
     concurrentes no pueden medir la misma memoria libre.
  """

  use ExUnit.Case, async: false

  alias Candil.FakeGPU
  alias Candil.Model
  alias Candil.Scheduler

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    FakeGPU.install(tmp_dir, total_mb: 16_303, free_mb: 16_000)
    on_exit(&FakeGPU.uninstall/0)
    :ok
  end

  defp model(opts \\ []) do
    %Model{
      alias: :test_model,
      type: :local,
      engine: :llama_cpp,
      context_size: 131_072,
      gpu_layers: Keyword.get(opts, :gpu_layers, -1),
      model_args: Keyword.get(opts, :model_args, []),
      model_dir: "/nonexistent",
      filename: "m.gguf"
    }
  end

  describe "las capas fijas" do
    test "un modelo que las fija NO se puede colocar" do
      # Sin esto, `llama-fit-params` aborta («n_gpu_layers already set by user
      # to 99»), no hay medición, y el motor arranca sin ajustar: que es como
      # se llena la VRAM y se para en seco.
      assert {:error, :gpu_layers_fixed} = Scheduler.plan(model(gpu_layers: 99))
    end

    test "con --n-cpu-moe sí se puede: los expertos se van a la RAM" do
      # La excepción: lo que queda en la VRAM cabe aunque las capas estén
      # fijadas, y el modelo arranca (su reserva NO se mide, y de eso avisa el
      # motor).
      m = model(gpu_layers: 99, model_args: ["--n-cpu-moe", "30"])

      assert {:ok, device} = Scheduler.plan(m)
      assert is_integer(device)
    end

    test "un modelo con -1 se coloca: se puede ajustar" do
      assert {:ok, device} = Scheduler.plan(model(gpu_layers: -1))
      assert is_integer(device)
    end

    test "un modelo de CPU no pide GPU" do
      assert {:ok, nil} = Scheduler.plan(model(gpu_layers: 0))
    end
  end

  describe "el tamaño de las instancias" do
    test "es el que dice nvidia-smi, no la estimación" do
      # El modelo NO declara `vram_mb`: la estimación son 512 MiB, y el
      # modelo ocupa 7978. Expulsarlo liberaría 7978, no 512.
      m = model()

      assert Scheduler.estimate_model_size(m) == 512
      assert Scheduler.size_mb(m, %{used_mb: 7978, device_index: 0}) == 7978
    end

    test "sin medición, es lo declarado" do
      m = %{model() | vram_mb: 3000}

      assert Scheduler.size_mb(m, nil) == 3000
    end

    test "sin medición y sin declaración, es la estimación" do
      assert Scheduler.size_mb(model(), nil) == 512
    end

    test "una medición de 0 MiB es 0, no la estimación" do
      # Un proceso que `nvidia-smi` dice que usa 0 MiB usa 0 MiB. La
      # estimación es un suelo para lo que NO se sabe, no para lo que se sabe.
      assert Scheduler.size_mb(model(), %{used_mb: 0, device_index: 0}) == 0
    end
  end

  describe "el cerrojo de colocación" do
    test "dos colocaciones no se solapan" do
      # La carrera: dos `start_placed/2` concurrentes miden la misma memoria
      # libre, los dos deciden que su modelo cabe, y el segundo recibe un
      # error de acquire que no explica nada.
      #
      # Con el cerrojo, el segundo espera. Aqui se mide: dos llamadas
      # seguidas, cada una con un segundo de trabajo dentro, tardan mas de dos
      # segundos — o sea, no se solaparon.
      medido =
        :timer.tc(fn ->
          tasks =
            for _ <- 1..2 do
              Task.async(fn ->
                Candil.Engine.Resource.with_placement_lock(fn ->
                  Process.sleep(1_000)
                  :ok
                end)
              end)
            end

          Enum.each(tasks, &Task.await(&1, 10_000))
        end)

      {micros, _} = medido

      # Solapadas habria sido ~1,0 s; en serie son ~2,0 s.
      assert micros > 1_500_000, "las dos colocaciones se solaparon (#{micros} us)"
    end

    test "el cerrojo devuelve lo que devuelve la función" do
      assert Candil.Engine.Resource.with_placement_lock(fn -> :ok end) == :ok
    end
  end
end
