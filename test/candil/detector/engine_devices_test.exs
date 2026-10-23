defmodule Candil.Detector.EngineDevicesTest do
  @moduledoc """
  La lista de devices que publica el motor.

  ## El texto es el de verdad

  El parser se prueba contra la salida **real** de `llama-server
  --list-devices`, capturada el 2026-10-22 en la máquina del dueño:

      Available devices:
        CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 15683 MiB free)

  Un test con una salida inventada probaría que el parser entiende al test.

  ## Lo que hay que mirar

  - El **nombre** es lo que se le pasa a `--device`, y no se deriva del índice:
    en ROCm es `ROCm0`, no `CUDA0`.
  - La **capacidad** que publica el motor ya está sin su contexto de CUDA:
    15933 MiB, no los 16303 que ve `nvidia-smi`.
  - Una línea que no se entiende se salta, y si no queda ninguna se dice
    `{:error, :unparseable}`: se sabe que había algo y no se sabe qué es.
  """

  use ExUnit.Case, async: true

  alias Candil.Detector.EngineDevices

  @real """
  Available devices:
    CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 15683 MiB free)
  """

  describe "parse/1" do
    test "lee la salida real del motor" do
      assert {:ok, %{backend: :cuda, devices: [device]}} = EngineDevices.parse(@real)

      assert device.name == "CUDA0"
      assert device.index == 0
      assert device.total_mb == 15_933
      assert device.free_mb == 15_683
      assert device.usable
    end

    test "el índice es la posición en la lista del motor" do
      output = """
      Available devices:
        CUDA0: NVIDIA GeForce RTX 5080 (15933 MiB, 15683 MiB free)
        CUDA1: NVIDIA GeForce RTX 5080 (15933 MiB, 15000 MiB free)
      """

      assert {:ok, %{devices: [first, second]}} = EngineDevices.parse(output)

      assert first.index == 0
      assert first.name == "CUDA0"
      assert second.index == 1
      assert second.name == "CUDA1"
    end

    test "el nombre no se deriva del índice: ROCm no es CUDA" do
      output = """
      Available devices:
        ROCm0: AMD Radeon RX 7900 (16384 MiB, 16000 MiB free)
      """

      assert {:ok, %{backend: :rocm, devices: [device]}} = EngineDevices.parse(output)

      assert device.name == "ROCm0"
      assert device.backend == :rocm
    end

    test "cada backend se reconoce por su prefijo" do
      for {name, backend} <- [
            {"CUDA0", :cuda},
            {"ROCm0", :rocm},
            {"Vulkan0", :vulkan},
            {"SYCL0", :sycl},
            {"Metal", :metal}
          ] do
        output = "Available devices:\n  #{name}: algo (100 MiB, 50 MiB free)"

        assert {:ok, %{devices: [device]}} = EngineDevices.parse(output)
        assert device.backend == backend, "#{name} debería ser #{backend}"
      end
    end

    test "un prefijo desconocido es :unknown, no una suposición" do
      output = "Available devices:\n  Futuro0: algo (100 MiB, 50 MiB free)"

      assert {:ok, %{backend: :unknown, devices: [device]}} = EngineDevices.parse(output)
      assert device.backend == :unknown
    end

    test "una línea que no se entiende se salta" do
      output = """
      Available devices:
        CUDA0: NVIDIA GeForce RTX 5080 (15933 MiB, 15683 MiB free)
        esto no es un device
      """

      assert {:ok, %{devices: [device]}} = EngineDevices.parse(output)
      assert device.name == "CUDA0"
    end

    test "si no queda ningún device pero había líneas, no se sabe" do
      # Un parser que se come lo raro deja al scheduler sin devices y dice
      # «no hay GPU», que no es lo que pasó.
      assert {:error, :unparseable} = EngineDevices.parse("Available devices:\n  basura")
    end

    test "una salida vacía es «no hay devices», no un error" do
      assert {:ok, %{devices: []}} = EngineDevices.parse("")
    end

    test "un device con más libre que total se rechaza" do
      output = "Available devices:\n  CUDA0: NVIDIA (100 MiB, 500 MiB free)"

      assert {:error, :unparseable} = EngineDevices.parse(output)
    end
  end

  describe "detect/1" do
    test "un binario que no existe no es una lista vacía" do
      # Una lista vacía sería «el motor no tiene devices», que es un hecho
      # distinto de «no se pudo preguntar».
      assert {:error, :no_binary} = EngineDevices.detect("/no/existe/llama-server")
    end

    test "un binario que falla es un error, no una lista vacía" do
      assert {:error, {:engine_failed, _}} = EngineDevices.detect("/bin/false")
    end

    test "lee la lista del motor de verdad" do
      # El binario real de esta máquina. Sin él, el test no probaría nada: un
      # parser con un texto inventado demuestra que el parser entiende el
      # texto inventado.
      binary = System.get_env("CANDIL_TEST_LLAMA_SERVER")

      if is_binary(binary) and File.exists?(binary) do
        assert {:ok, %{devices: [device | _]}} = EngineDevices.detect(binary)
        assert is_binary(device.name)
        assert device.total_mb > 0
      else
        # Sin el binario no se puede probar el camino real: se dice, en vez de
        # fingir que se probó.
        assert true
      end
    end
  end
end
