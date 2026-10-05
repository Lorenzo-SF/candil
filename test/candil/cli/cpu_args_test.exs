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

  # ── la migración: el flag escondido pasa a ser campo ────────────────────

  @tag timeout: 120_000
  test "un --n-gpu-layers escondido en model_args se muda al campo" do
    # El toml del usuario tiene el flag DENTRO de model_args, y mientras este
    # ahi `--cpu` no lo puede tocar. Hydrate lo saca de ahi.
    hydrated_model(
      spec(%{
        "model_args" => [
          "--alias",
          "qwencoder",
          "-fa",
          "on",
          "--log-verbosity",
          "3",
          "--n-gpu-layers",
          "-1",
          "--n-cpu-moe",
          "30",
          "--temp",
          "0.7"
        ]
      })
    )

    # `hydrate/1` devuelve la lista de ALIAS registrados, no los structs. Lo que
    # se comprueba es lo mismo que leeria el engine: el Store.
    {:ok, found} = Store.get_model(:m)

    assert found.gpu_layers == -1
    refute "--n-gpu-layers" in found.model_args
    # Con el flag en MEDIO, no al principio. Con el flag primero el bug es
    # invisible: no hay nada antes que perder, y el test pasa igual. Este caso
    # es el que se llevo por delante `--alias`, `-fa` y `--log-verbosity`.
    assert found.model_args == [
             "--alias",
             "qwencoder",
             "-fa",
             "on",
             "--log-verbosity",
             "3",
             "--n-cpu-moe",
             "30",
             "--temp",
             "0.7"
           ]
  end

  @tag timeout: 120_000
  test "un gpu_layers explicito gana sobre el flag en model_args" do
    hydrated_model(
      spec(%{
        "gpu_layers" => 20,
        "model_args" => ["--n-gpu-layers", "99", "--temp", "0.7"]
      })
    )

    {:ok, found} = Store.get_model(:m)

    # El campo manda, y el flag sobrante se quita igualmente: dos fuentes de
    # verdad para el mismo numero es justo como se cuela un "already set by
    # user" que nadie sabe de donde sale.
    assert found.gpu_layers == 20
    refute "--n-gpu-layers" in found.model_args
  end

  @tag timeout: 120_000
  test "sin gpu_layers y sin flag, sale el -1 de llama-server" do
    hydrated_model(spec(%{"model_args" => ["--temp", "0.7"]}))

    {:ok, found} = Store.get_model(:m)
    assert found.gpu_layers == -1
  end

  defp spec(extra) do
    Map.merge(
      %{"engine" => "e", "source" => %{"kind" => "local", "path" => "/tmp/m.gguf"}},
      extra
    )
  end

  defp hydrated_model(model_spec) do
    Candil.Config.Hydrate.hydrate(%{"model" => %{"m" => model_spec}})
  end

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
      model_args: ["--temp", "0.7"],
      # Lo que hay en tu toml HOY, dentro de model_args. Hydrate lo saca de
      # ahi y lo deja en el campo, para que `--cpu` pueda tocarlo.
      gpu_layers: 99
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
