defmodule Candil.Detector.DevicesTest do
  @moduledoc """
  El parser se prueba contra **la salida real de `nvidia-smi`**, copiada del
  formato documentado, porque en un runner sin GPU no hay otra forma de saber
  si el parser funciona o si simplemente nunca se ha ejecutado.

  Y ese es el punto de este fichero: hoy `Candil` no sabe cuantas GPUs tiene ni
  cuanta VRAM. La columna `SLOT` de `candil status` no viene del hardware:

      defp slot(port), do: if(rem(port, 100) >= 90, do: "dGPU", else: "CPU")

  Sale del **numero de puerto**. Cualquier puerto acabado en 9x es "dGPU" por
  definicion, y no hay ningun campo `device` en el modelo. Sin esto, la 8b
  (¿que motor se queda? ¿que se descarga?) no tiene de donde sacar la
  pregunta.
  """
  use ExUnit.Case, async: true

  alias Candil.Detector.Devices

  # ── Lo que sale de verdad ───────────────────────────────────────────────────
  #
  # $ nvidia-smi --query-gpu=index,name,memory.total,memory.free \
  #       --format=csv,noheader,nounits
  # 0, NVIDIA GeForce RTX 5080, 16376, 16100
  @one """
  0, NVIDIA GeForce RTX 5080, 16376, 16100
  """

  @two """
  0, NVIDIA GeForce RTX 5080, 16376, 16100
  1, NVIDIA GeForce RTX 5080, 16376, 16300
  """

  # Sin `nounits` la cifra llega con la unidad pegada.
  @with_units """
  0, NVIDIA GeForce RTX 5080, 16376 MiB, 16100 MiB
  """

  # Asi sale si alguien se olvida del `noheader`.
  @with_header """
  index, name, memory.total [MiB], memory.free [MiB]
  0, NVIDIA GeForce RTX 5080, 16376, 16100
  """

  # Documentado por NVIDIA: un valor no soportado se imprime como "N/A".
  @with_na """
  0, NVIDIA A100-SXM4-40GB, N/A, N/A
  """

  describe "una GPU" do
    test "se lee indice, nombre, total y libre" do
      assert {:ok,
              [%{index: 0, name: "NVIDIA GeForce RTX 5080", total_mb: 16_376, free_mb: 16_100}]} =
               Devices.parse_nvidia(@one)
    end

    test "el nombre con espacios se lee entero, no se parte en dos" do
      {:ok, [device]} = Devices.parse_nvidia(@one)
      assert device.name == "NVIDIA GeForce RTX 5080"
    end
  end

  describe "varias GPUs" do
    test "cada linea es un dispositivo y conserva su indice" do
      assert {:ok, devices} = Devices.parse_nvidia(@two)
      assert length(devices) == 2
      assert Enum.map(devices, & &1.index) == [0, 1]
      assert Enum.map(devices, & &1.free_mb) == [16_100, 16_300]
    end

    test "el indice NO se recalcula por posicion" do
      # Las GPUs se pueden reenumerar. El indice es lo que dice nvidia-smi.
      assert {:ok, [%{index: 3}, %{index: 7}]} =
               Devices.parse_nvidia("""
               3, NVIDIA A, 16376, 16000
               7, NVIDIA B, 16376, 16000
               """)
    end
  end

  describe "unidades" do
    test "con units pegadas tambien se lee, porque el comando puede cambiar" do
      assert {:ok, [%{total_mb: 16_376, free_mb: 16_100}]} = Devices.parse_nvidia(@with_units)
    end
  end

  describe "lo que NO se debe Inventar" do
    test "sin GPU NO es un error: es una lista vacia" do
      # `nvidia-smi -L` en una maquina sin NVIDIA sale con codigo distinto de 0.
      # Un `{:error, :no_gpu}` obliga a tratar "no hay" como si fuera "fallo",
      # y quien llama no puede distinguirlos.
      assert {:ok, []} = Devices.parse_nvidia("")
      assert {:ok, []} = Devices.parse_nvidia("\n\n")
    end

    test "N/A NO es cero: un dispositivo sin memoria legible no es utilizable" do
      # Este es el fallo silencioso que hay que evitar a proposito. Si "N/A"
      # se convierte en 0, el planificador cree que hay 0 MiB libres y dice
      # "no cabe" con un numero inventado; si se convierte en el total, cree
      # que la GPU esta libre y lanza un modelo que no entra.
      assert {:ok, [device]} = Devices.parse_nvidia(@with_na)
      assert device.usable == false
      assert device.total_mb == nil
      assert device.free_mb == nil
    end

    test "un dispositivo con la memoria a medias NO se dice que esta libre" do
      # N/A en un campo y numero en el otro: tampoco se rellena el hueco.
      assert {:ok, [device]} = Devices.parse_nvidia("0, NVIDIA A, 16376, N/A")
      assert device.usable == false
      assert device.total_mb == 16_376
      assert device.free_mb == nil
    end

    test "la cabecera no se convierte en un dispositivo con indice 0" do
      # Si el comando pierde el `noheader`, la primera linea es texto. Sin esto,
      # sale un dispositivo llamado "index" con la memoria del literal "name".
      {:ok, devices} = Devices.parse_nvidia(@with_header)
      refute Enum.any?(devices, &(&1.name == "index"))
      assert [%{index: 0, name: "NVIDIA GeForce RTX 5080"}] = devices
    end

    test "basura no es un dispositivo" do
      assert {:error, _} =
               Devices.parse_nvidia("Failed to initialize NVML: Driver/library version mismatch")

      assert {:error, _} = Devices.parse_nvidia("0, NVIDIA")
    end

    test "el total nunca es menor que el libre" do
      # Una linea donde no tiene sentido es una linea que no es un dispositivo.
      assert {:error, _} = Devices.parse_nvidia("0, NVIDIA A, 100, 200")
    end

    test "la memoria libre es la que dice nvidia-smi, no total menos usada" do
      # nvidia-smi separa reserved de used. Calcularlo aqui seria inventar.
      assert {:ok, [%{free_mb: free, total_mb: 16_376}]} =
               Devices.parse_nvidia("0, NVIDIA GeForce RTX 5080, 16376, 9000")

      assert free == 9000
    end
  end

  describe "el contrato del modulo" do
    test "el backend se declara aunque no haya dispositivos" do
      # "no hay GPUs" y "no se puede preguntar" son hechos distintos, y los dice
      # quien puede saberlos: una salida vacia de un nvidia-smi que existe es
      # que no hay; el "no se puede preguntar" lo dice detect_cuda/0.
      assert {:ok, %{backend: :cuda, devices: []}} = Devices.parse("", :cuda)
    end

    test "una salida en blanco es que no hay, y solo en blanco" do
      # El `{:error, :no_smi}` NO es de aqui: es de `detect_cuda/0`, que es quien
      # sabe si el binario existe. Este sandbox **si** lo verifica, porque no
      # tiene nvidia-smi: ahi `detect_cuda/0` da `{:error, :no_smi}` de verdad.
      assert {:ok, %{backend: :cuda, devices: []}} = Devices.parse("  \n", :cuda)
    end

    test "una linea de basura con lineas buenas no tira el resultado entero" do
      assert {:ok, devices} =
               Devices.parse_nvidia("""
               0, NVIDIA A, 16376, 16000
               No se ha podido determinar el tamaño
               1, NVIDIA B, 16376, 16000
               """)

      assert length(devices) == 2
    end
  end
end
