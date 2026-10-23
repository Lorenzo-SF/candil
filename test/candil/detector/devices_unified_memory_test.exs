defmodule Candil.Detector.DevicesUnifiedMemoryTest do
  @moduledoc """
  La memoria unificada de macOS: el total **no** es el libre.

  ## El bug

  `unified_memory/0` guardaba el total de `hw.memsize` en los dos campos —
  `total_mb` y `free_mb`— y lo marcaba `usable: true`. El scheduler veía
  memoria libre que no había, y `Resource.sync_foreign/1` —que busca enteros
  para ajustar el titular `:foreign`— no encontraba nada que ajustar.

  D-28 lo dice así: *«`unified_memory/0` no devuelve `free = total` con
  `usable: true`»*.

  ## La salida de `vm_stat`

  Es un texto de macOS, no de Candil: el formato es el de `vm_stat(1)`. Este
  parser se prueba contra una muestra de ese formato, con el tamaño de página
  que publica la cabecera —que **cambia** entre máquinas (4096 en Intel, 16384
  en Apple Silicon)—.
  """

  use ExUnit.Case, async: true

  alias Candil.Detector.Devices

  @vm_stat """
  Mach Virtual Memory Statistics: (page size of 16384 bytes)
  Pages free:                               12345.
  Pages active:                            234567.
  Pages inactive:                           11111.
  Pages speculative:                         2222.
  Pages throttled:                              0.
  Pages wired down:                        34567.
  Pages purgeable:                           3333.
  "Translation faults":                  123456789.
  Pages copy-on-write:                   12345678.
  """

  describe "parse_vm_stat/1" do
    test "la memoria disponible son las páginas recuperables" do
      # free + inactive + speculative + purgeable = 12345 + 11111 + 2222 + 3333
      # = 29 011 páginas de 16384 bytes = 464 176 KiB = 453 MiB.
      assert {:ok, mb} = Devices.parse_vm_stat(@vm_stat)

      assert mb == 453
    end

    test "el tamaño de página se lee de la cabecera, no se supone" do
      # 4096 bytes por página: la misma muestra son 113 MiB.
      output = String.replace(@vm_stat, "page size of 16384 bytes", "page size of 4096 bytes")

      assert {:ok, mb} = Devices.parse_vm_stat(output)

      assert mb == 113
    end

    test "sin tamaño de página no se sabe" do
      output = String.replace(@vm_stat, ~r/\(page size of \d+ bytes\)/, "")

      assert {:error, :no_page_size} = Devices.parse_vm_stat(output)
    end

    test "si falta una de las clases, no se sabe" do
      output = String.replace(@vm_stat, ~r/Pages purgeable:.*\n/, "")

      assert {:error, {:missing, missing}} = Devices.parse_vm_stat(output)
      assert "Pages purgeable" in missing
    end
  end
end
