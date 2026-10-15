defmodule Candil.Detector.ProcessesTest do
  @moduledoc """
  Cuanta VRAM gasta **cada proceso**, no cada GPU.

  `Devices.parse_nvidia/1` dice cuanto hay libre en total, y eso no sirve para
  una tabla con varios modelos: con dos instances corriendo no hay forma de
  saber cuanto gasta cada una. `nvidia-smi --query-compute-apps` si lo dice,
  y lo dice por PID —que es justo lo que `candil status` ya tiene en una
  columna.

  Medido el 2026-10-15 con un `llama-server` de verdad cargado:

      $ nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory \\
            --format=csv,noheader
      660483, /usr/bin/kwin_wayland, 12 MiB
      4063979, /home/lorenzo/.local/bin/llama-server, 12674 MiB

  Y en la misma instante `memory.used` de la GPU decia 528 MiB con el
  compositor a 12: los dos numeros son del mismo sitio y no se contradicen,
  son preguntas distintas.
  """

  use ExUnit.Case, async: true

  alias Candil.Detector.Devices

  # La salida real, con el compositor de por medio. Es la de la consulta de dos
  # columnas, `pid,used_gpu_memory`, que es la que usa el modulo; con unidades
  # sale igual pero el numero viene con "MiB" pegado.
  @real """
  660483, 12
  4063979, 12674
  """

  @con_unidades """
  660483, 12 MiB
  4063979, 12674 MiB
  """

  # Sin nada corriendo: la consulta devuelve una linea vacia, no un error.
  @vacia "\n"

  describe "la salida real" do
    test "se parte en pid y MiB" do
      assert {:ok, procesos} = Devices.parse_processes(@real)
      assert length(procesos) == 2

      assert Enum.find(procesos, &(&1.pid == 4_063_979)).used_mb == 12_674
      assert Enum.find(procesos, &(&1.pid == 660_483)).used_mb == 12
    end

    test "con las unidades pegadas tambien" do
      # `nounits` las quita, pero el modulo no debe depender de un flag para
      # entender un numero. Un cambio en la llamada no puede cambiar el parser.
      assert Devices.parse_processes(@con_unidades) == Devices.parse_processes(@real)
    end
  end

  describe "nada corriendo" do
    test "es una lista vacia y no un error" do
      # `Devices` distingue «no hay GPUs» de «no se puede preguntar». Aqui lo
      # que se pregunta es si ALGO USA la GPU, y la respuesta es que no: no es
      # un fallo del que avisar.
      assert Devices.parse_processes(@vacia) == {:ok, []}
    end
  end

  describe "lo que no se debe inventar" do
    test "una linea que no se entiende no se salta en silencio" do
      # Un parser que se come lo raro devuelve una lista mas corta y nadie se
      # entera. Con `{:error, _}` el que llama decide.
      assert {:error, :bad_line} = Devices.parse_processes("esto no es una linea\n")
    end

    test "un MiB que no es un numero es un fallo, no un 0" do
      # Un `0` aqui significa «este proceso no usa GPU», que es una verdad que
      # se puede usar. Un `-1` seria lo mismo con distinta forma.
      assert {:error, :bad_line} = Devices.parse_processes("1234, proceso, muchisima\n")
    end

    test "y un pid que no lo es tambien" do
      assert {:error, :bad_line} = Devices.parse_processes("mucho, proceso, 12 MiB\n")
    end
  end
end
