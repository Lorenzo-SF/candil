defmodule Candil.DebugCpuArgsTest do
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
  test "debug", %{tmp_dir: tmp_dir} do
    argv_file = Path.join(tmp_dir, "argv-cpu.json")
    binary = Path.join(tmp_dir, "engine-cpu")

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
      model_args: ["--temp", "0.7"],
      gpu_layers: 99
    })

    engine = Candil.Store.get_engine(:argv_e) |> elem(1)
    model = Candil.Store.get_model(:argv_m) |> elem(1)

    IO.puts("binary_path: #{Candil.Engine.binary_path(engine)}")
    # IO.puts("fit_binary: #{Candil.Engine.FitParams.fit_binary(engine) |> inspect()}")

    result = Candil.Engine.start(engine, model, 0)
    IO.puts("Engine.start result: #{inspect(result)}")
  end
end
