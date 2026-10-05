defmodule Candil.CLITest.CpuArgsTest do
  @moduledoc """
  El argv que se EJECUTA, no el que devuelve una función.

  Toda la historia de `--cpu` ha sido esto: la función que reescribe los
  argumentos estaba bien probada —o mal probada, en su mayoría— y lo que no
  estaba probado era que el flag **llegara** hasta ella. Ocho tests sobre
  `Args.for_cpu/2` y ninguno sobre el camino entero, y el resultado fue un
  `llama-server` recibiendo `--n-gpu-layers 99` después de que el usuario
  hubiera escrito `--cpu` en la línea de comandos.

  Aquí se arranca de verdad, con un binario que **escribe sus propios argv** en
  un fichero, y se lee ese fichero. Si mañana `--cpu` deja de llegar, este test
  se cae solo, que es justo lo que no hacía el otro.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Candil.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("CANDIL_DATA_DIR")
    System.put_env("CANDIL_DATA_DIR", Path.join(tmp_dir, "data"))
    on_exit(fn -> if previous, do: System.put_env("CANDIL_DATA_DIR", previous) end)

    Process.flag(:trap_exit, true)
    :ok
  end

  @tag timeout: 120_000
  test "con --cpu, el argv que se ejecuta lleva --n-gpu-layers 0", %{tmp_dir: tmp_dir} do
    argv = run_and_capture_argv(tmp_dir, "cpu")

    # Lo que se mira NO es `Args.for_cpu/2` sino lo que el proceso recibe.
    assert last_flag_value(argv, "--n-gpu-layers") == "0",
           """
           Candil se ha lancerado `--cpu` y el engine ha recibido:
             #{inspect(argv)}

           El flag no ha llegado, o llama-server se ha quedado con el 99 del
           toml en vez de con el 0 que va detras.
           """

    assert has_flag?(argv, "--threads"),
           "con --cpu tambien van los hilos: un 27B en CPU sin --threads tarda cuatro veces mas"
  end

  @tag timeout: 120_000
  test "sin --cpu, el argv del toml llega intacto", %{tmp_dir: tmp_dir} do
    argv = run_and_capture_argv(tmp_dir, "gpu")

    assert last_flag_value(argv, "--n-gpu-layers") == "99"
    refute has_flag?(argv, "--threads")
  end

  # Arranca `candil run <model>` de verdad contra un binario que escribe lo que
  # recibe, y devuelve ese argv.
  defp run_and_capture_argv(tmp_dir, mode) do
    argv_file = Path.join(tmp_dir, "argv-#{mode}.json")
    binary = Path.join(tmp_dir, "engine-#{mode}")

    # El binario de mentira ESCRIBE sus argv y sale. No importa que no
    # responda: lo que se comprueba es lo que recibio.
    File.write!(
      binary,
      ~s|#!/bin/sh\nprintf '%s\\n' "$@" > #{argv_file}\nexit 0\n|
    )

    File.chmod!(binary, 0o755)
    :ok = File.write!(Path.join(tmp_dir, "m.gguf"), "x")

    Store.register_engine(%Candil.Engine{
      alias: :argv_e,
      binary: binary,
      port: 19_991
    })

    Store.register_model(%Candil.Model{
      alias: :argv_m,
      engine: :argv_e,
      type: :local,
      context_size: 1024,
      port: 19_991,
      model_dir: tmp_dir,
      filename: "m.gguf",
      # El 99 es lo que hay en el toml del usuario, y es el que se cuela.
      model_args: ["--n-gpu-layers", "99", "--temp", "0.7"]
    })

    opts =
      case mode do
        "cpu" -> %{model: "argv_m", port: 19_991, cpu: true}
        "gpu" -> %{model: "argv_m", port: 19_991}
      end

    capture_io(fn -> Candil.CLI.Lifecycle.run_model(opts) end)

    unless File.exists?(argv_file) do
      flunk("el engine no llegó a arrancar; no hay argv que mirar")
    end

    argv_file
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp last_flag_value(argv, flag) do
    argv
    |> Enum.with_index()
    |> Enum.filter(fn {a, _i} -> a == flag end)
    |> Enum.map(fn {_a, i} -> Enum.at(argv, i + 1) end)
    |> List.last()
  end

  defp has_flag?(argv, flag), do: flag in argv
end
