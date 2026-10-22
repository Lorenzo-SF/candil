defmodule Candil.CLI.StopReleasesVRAMTest do
  @moduledoc """
  `candil stop` tiene que soltar la **VRAM**, no solo la entrada del registro.

  Medido el 2026-10-21: `candil stop` decia «1 instancia parada», el registro
  quedaba vacío y `candil status` decia «no hay instancias»… mientras el
  `llama-server` seguía vivo con **8116 MiB de VRAM cogidos**.

  La causa: el dueño de una instancia detached es un escript, y el motor es un
  **nieto** suyo —otro proceso del sistema operativo—. Matar al dueño no se
  lleva por delante al nieto, así que el motor se queda huérfano y la GPU
  ocupada con nada que la esté usando.

  Es el bug que el moduledoc de `Arrea.LongRunning.OsProcessTest` describe como
  arreglado, y que ha vuelto por el camino del `--detach`.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("CANDIL_DATA_DIR")
    System.put_env("CANDIL_DATA_DIR", tmp_dir)
    on_exit(fn -> if previous, do: System.put_env("CANDIL_DATA_DIR", previous) end)
    :ok
  end

  describe "el stop de una instancia detached" do
    @tag timeout: 60_000
    test "mata tambien el motor, que es otro proceso", %{tmp_dir: tmp_dir} do
      # Un proceso real que se pueda observar. No es un modelo: lo que se
      # comprueba es que el `stop` llega al **segundo** pid, el del motor, y no
      # solo al dueno.
      # Dos procesos reales: el dueno y el motor. Los dos tienen que estar
      # vivos, porque `Instances.read/0` poda las entradas cuyo dueno no lo
      # esta —una instancia con dueno muerto no es una instancia—.
      owner_pidfile = Path.join(tmp_dir, "owner.pid")
      pidfile = Path.join(tmp_dir, "motor.pid")

      # En segundo plano: `System.cmd` espera a que el comando termine, y estos
      # no terminan nunca.
      for file <- [owner_pidfile, pidfile] do
        System.cmd(
          "sh",
          ["-c", "nohup sh -c 'echo $$ > #{file}; sleep 600' >/dev/null 2>&1 &"],
          stderr_to_stdout: true
        )
      end

      owner_pid = wait_for_pid(owner_pidfile)
      engine_pid = wait_for_pid(pidfile)

      assert alive?(engine_pid), "el proceso de prueba tiene que estar vivo"

      instance = %{
        model: "coder",
        port: 9999,
        pid: owner_pid,
        engine_pid: engine_pid,
        owner: %{kind: :pid, pid: owner_pid},
        host: "127.0.0.1",
        engine: "llama_cpp",
        started_at: "2026-10-21T00:00:00Z",
        healthy: true
      }

      :ok = Candil.Instances.put({"coder", 9999}, instance)

      assert [entry] = Candil.Instances.read()
      assert entry.engine_pid == engine_pid

      Candil.CLI.Lifecycle.stop(model: "coder")

      # El motor tiene que estar muerto. Antes seguia vivo con la VRAM cogida.
      assert eventually_dead?(engine_pid),
             "el motor (pid #{engine_pid}) sigue vivo: el stop no lo ha matado"

      # Y el dueno tambien, que es lo que hacia antes.
      assert eventually_dead?(owner_pid)

      # Y el registro ya no lo tiene.
      assert Candil.Instances.read() == []
    end
  end

  defp wait_for_pid(path, tries \\ 50) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) |> Integer.parse() do
          {pid, ""} -> pid
          _ -> retry(path, tries)
        end

      _ ->
        retry(path, tries)
    end
  end

  defp retry(_path, 0), do: 0
  defp retry(path, tries), do: Process.sleep(100) && wait_for_pid(path, tries - 1)

  defp alive?(pid) do
    {_out, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    code == 0
  end

  defp eventually_dead?(pid, tries \\ 50) do
    cond do
      not alive?(pid) -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually_dead?(pid, tries - 1)
    end
  end
end
