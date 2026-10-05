defmodule Candil.CLI.HolderShutdownTest do
  @moduledoc """
  When the holder stops, the OS process goes with it.

  The whole design rests on C19: *kill the owner and the engine goes with it,
  because the engine was never detached from it.* But `llama-server` is an OS
  process, not an Erlang one. When the holder's VM exits, the operating system
  reparents it to init and it lives on: holding VRAM, holding a port, and
  unreachable by `candil stop` because the registry record is pruned the
  moment the owner's pid disappears.

  That is what the user hit — `ropero status` reporting `ON` with 14 GB of
  VRAM while `candil status` reported nothing. Both true, about different
  things.

  So this test spawns a real process through Arrea —the same path the engine
  takes— gives it a marker unique to this test, and checks it is gone after
  `Holder.block/1` returns.
  """
  use ExUnit.Case, async: false

  alias Candil.CLI.Holder

  @moduletag :tmp_dir

  @marker "candil-holder-shutdown-probe"

  @tag timeout: 120_000
  test "el titular para el proceso del sistema operativo al salir", %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "engine-#{@marker}")
    pidfile = Path.join(tmp_dir, "engine.pid")

    # El proceso escribe su propio pid y se queda. Nada de `exec -a`, que es
    # de bash y no de sh, y sale con 127.
    File.write!(bin, "#!/bin/sh\necho $$ > #{pidfile}\nsleep 600\n")
    File.chmod!(bin, 0o755)

    id = {:candil_engine, :holder_probe, 19_993}

    {:ok, _lr} = Arrea.LongRunning.start_link(id: id, binary: bin, args: [])

    # El pid del SO es el que importa: el proceso que se queda con la VRAM.
    # El del puerto de Erlang pertenece a otro mundo y muere con el VM.
    os_pid = wait_for_pid_file(pidfile)
    assert os_pid, "el proceso de prueba no aparecio"
    assert alive?(os_pid), "el proceso de prueba deberia estar vivo"

    holder = spawn(fn -> Holder.block(id) end)
    ref = Process.monitor(holder)

    send(holder, :stop)

    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 30_000

    assert eventually_gone?(os_pid),
           """
           el titular ha salido pero el proceso del sistema operativo sigue vivo
           (pid #{os_pid}). Sin apagarlo explicitamente antes de salir queda
           huerfano, con la VRAM cogida y sin que `candil stop` lo alcance.
           """
  end

  defp wait_for_pid_file(path, tries \\ 50) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.trim() |> Integer.parse() do
          {pid, _} -> pid
          :error -> retry(path, tries)
        end

      _ ->
        retry(path, tries)
    end
  end

  defp retry(_path, 0), do: nil
  defp retry(path, tries), do: Process.sleep(100) && wait_for_pid_file(path, tries - 1)

  defp alive?(os_pid), do: match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)]))

  defp eventually_gone?(os_pid, tries \\ 50) do
    cond do
      not alive?(os_pid) -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually_gone?(os_pid, tries - 1)
    end
  end
end
