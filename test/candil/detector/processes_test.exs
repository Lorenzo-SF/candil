defmodule Candil.Detector.ProcessesTest do
  @moduledoc """
  Cuanta VRAM gasta **cada proceso**, no cada GPU, y en qué tarjeta.

  `Devices.parse_nvidia/1` dice cuanto hay libre en total, y eso no sirve para
  una tabla con varios modelos: con dos instances corriendo no hay forma de
  saber cuanto gasta cada una. `nvidia-smi --query-compute-apps` si lo dice,
  y lo dice por PID —que es justo lo que `candil status` ya tiene en una
  columna—. Y `gpu_uuid` dice en qué tarjeta, que es lo que el scheduler
  necesita para no adivinar por el puerto (D-16).

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

  @uuid "GPU-bd325fc5-c501-a2bb-86e2-a2aeb5017114"

  @uuid_to_index %{@uuid => 0}

  # La salida real, con el UUID delante. Es la de la consulta de tres
  # columnas, `gpu_uuid,pid,used_gpu_memory`, que es la que usa el modulo; con
  # unidades sale igual pero el numero viene con "MiB" pegado.
  @real """
  #{@uuid}, 660483, 12
  #{@uuid}, 4063979, 12674
  """

  @con_unidades """
  #{@uuid}, 660483, 12 MiB
  #{@uuid}, 4063979, 12674 MiB
  """

  # Sin nada corriendo: la consulta devuelve una linea vacia, no un error.
  @vacia "\n"

  describe "la salida real" do
    test "se parte en pid, MiB y dispositivo" do
      assert {:ok, procesos} = Devices.parse_processes(@real, @uuid_to_index)
      assert length(procesos) == 2

      llama = Enum.find(procesos, &(&1.pid == 4_063_979))
      assert llama.used_mb == 12_674
      assert llama.device_index == 0

      assert Enum.find(procesos, &(&1.pid == 660_483)).device_index == 0
    end

    test "con las unidades pegadas tambien" do
      # `nounits` las quita, pero el modulo no debe depender de un flag para
      # entender un numero. Un cambio en la llamada no puede cambiar el parser.
      assert Devices.parse_processes(@con_unidades, @uuid_to_index) ==
               Devices.parse_processes(@real, @uuid_to_index)
    end

    test "un UUID que no esta en el mapa es device_index nil, no 0" do
      # El proceso se midio; lo que no se sabe es en que tarjeta. `nil` es el
      # hecho, y el scheduler no lo trata como «device 0».
      assert {:ok, [proceso]} = Devices.parse_processes("#{@uuid}, 123, 42\n", %{})
      assert proceso.device_index == nil
    end
  end

  describe "parse_gpu_uuid/1" do
    test "mapea UUID a index" do
      output = "0, #{@uuid}\n1, GPU-otra\n"
      assert Devices.parse_gpu_uuid(output) == %{@uuid => 0, "GPU-otra" => 1}
    end

    test "una linea que no se entiende se salta, no revienta" do
      # Perder un UUID solo deja sus procesos con `device_index: nil`, que es
      # un hecho; reventar la deteccion entera seria peor que no saber uno.
      assert Devices.parse_gpu_uuid("basura\n0, #{@uuid}\n") == %{@uuid => 0}
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
      assert {:error, :bad_line} =
               Devices.parse_processes("#{@uuid}, 1234, muchisima\n")
    end

    test "y un pid que no lo es tambien" do
      assert {:error, :bad_line} = Devices.parse_processes("#{@uuid}, mucho, 12 MiB\n")
    end
  end
end
