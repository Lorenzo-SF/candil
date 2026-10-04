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
    System.put_env("CANDIL_DATA_DIR", dir)
    on_exit(fn -> if previous, do: System.put_env("CANDIL_DATA_DIR", previous) end)
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
