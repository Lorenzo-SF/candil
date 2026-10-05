defmodule Candil.Engine.LogTest do
  @moduledoc """
  The engine's own words have to land in a file a person can read.

  `Arrea.LongRunning` hands the child's stdout/stderr to
  `[:arrea, :long_running, :data]` and the crash reason to
  `[:arrea, :long_running, :crashed]`. Nothing subscribed, so `llama-server`
  explaining itself in one line went nowhere, and the log that `run --detach`
  announces held nothing but the holder's own summary of the symptom.

  These tests drive the handler the same way `:telemetry` would.
  """
  use ExUnit.Case, async: false

  alias Candil.{Engine.Log, Instances}

  setup do
    dir = Path.join(System.tmp_dir!(), "candil-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("CANDIL_DATA_DIR")
    previous_log = System.get_env("CANDIL_LOG_DIR")

    System.put_env("CANDIL_DATA_DIR", dir)
    # `CANDIL_LOG_DIR`, NO `CANDIL_DATA_DIR`: el `log_dir` del toml gana
    # siempre —`doctor --fix` lo promete— asi que un test que solo PONGA
    # `CANDIL_DATA_DIR` sigue escribiendo en el log real de quien lanza la
    # suite. Que es exactamente lo que paso: el test se leyo a si mismo las
    # lineas del titular de una ejecucion anterior.
    System.put_env("CANDIL_LOG_DIR", Path.join(dir, "logs"))

    on_exit(fn ->
      if previous,
        do: System.put_env("CANDIL_DATA_DIR", previous),
        else: System.delete_env("CANDIL_DATA_DIR")

      if previous_log,
        do: System.put_env("CANDIL_LOG_DIR", previous_log),
        else: System.delete_env("CANDIL_LOG_DIR")
    end)

    # El log se vacia antes de cada test. Sin esto, el fichero se ANADE y el
    # test lee lo que dejo la ejecucion anterior —que fue como se acabo
    # escribiendo en el log real de la maquina que lanza la suite.
    File.rm_rf(Path.join(dir, "logs"))
    {:ok, dir: dir}
  end

  test "la salida del engine se anade al log de su modelo y puerto" do
    id = {:candil_engine, :coder, 9999}

    Log.handle_event(
      [:arrea, :long_running, :data],
      %{data: ["load ", "ok\n"], id: id},
      nil,
      self()
    )

    Log.handle_event([:arrea, :long_running, :data], %{data: ["done\n"], id: id}, nil, self())

    # Aislado por `async: false` y con `CANDIL_DATA_DIR` propio, para no
    # pisar el log de otro test que este corriendo a la vez.
    assert File.read!(log_path("coder", 9999)) == "load ok\ndone\n"
  end

  test "el motivo de la caida se escribe con el texto del engine, no en vez de el" do
    id = {:candil_engine, :analyst, 9998}

    Log.handle_event(
      [:arrea, :long_running, :data],
      %{data: ["error: unknown argument\n"], id: id},
      nil,
      self()
    )

    Log.handle_event(
      [:arrea, :long_running, :crashed],
      %{reason: :non_zero_exit, id: id},
      nil,
      self()
    )

    text = File.read!(log_path("analyst", 9998))
    # La linea que habria evitado una tarde entera de diagnostico.
    assert text =~ "error: unknown argument"
    assert text =~ "non_zero_exit"
  end

  test "cada puerto tiene su log, que es para lo que va el puerto en el id" do
    Log.handle_event(
      [:arrea, :long_running, :data],
      %{data: ["a\n"], id: {:candil_engine, :coder, 9999}},
      nil,
      self()
    )

    Log.handle_event(
      [:arrea, :long_running, :data],
      %{data: ["b\n"], id: {:candil_engine, :coder, 9998}},
      nil,
      self()
    )

    assert File.read!(log_path("coder", 9999)) == "a\n"
    assert File.read!(log_path("coder", 9998)) == "b\n"
  end

  test "un exit con codigo se registra, que es la salida NORMAL de un binario que no arranca" do
    id = {:candil_engine, :coder, 9999}

    Log.handle_event([:arrea, :long_running, :stopped], %{id: id, exit_code: 1}, nil, self())

    # `:stopped` y no `:crashed`: Arrea emite `crashed` solo para un
    # `{:EXIT, port, reason}`. Un binario que se niega a arrancar sale con
    # codigo, y ese camino no se registraba.
    text = File.read!(log_path("coder", 9999))
    assert text =~ "codigo 1"
  end

  test "un id que no es nuestro no rompe nada" do
    assert Log.slot({:otro, :proceso, 1}) == nil

    assert :ok =
             Log.handle_event(
               [:arrea, :long_running, :data],
               %{data: ["x"], id: :raro},
               nil,
               self()
             )
  end

  test "un evento desconocido se ignora en vez de reventar" do
    assert :ok = Log.handle_event([:otro, :evento, :nuevo], %{a: 1}, nil, self())
  end

  defp log_path(model, port) do
    Path.join([Instances.log_dir(), "#{model}-#{port}.log"])
  end
end
