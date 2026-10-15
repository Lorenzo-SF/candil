defmodule Candil.CLI.LifecycleVRAMTest do
  @moduledoc """
  La columna `VRAM` de `candil status`: cuanto gasta CADA instancia.

  `GPU LAYERS` dice cuantas capas van a GPU, que es lo que se le pidio al
  modelo —no cuanto ocupa—. Con dos modelos cargados no habia ninguna cifra de
  memoria en ningun sitio, y saber cuanto ocupa cada uno es justo lo que hace
  falta para decidir si cabe un tercero.

  Se atribuye por PID, que es lo que `nvidia-smi --query-compute-apps`
  devuelve y lo que la tabla ya tenia en una columna.
  """

  use ExUnit.Case, async: false

  alias Candil.CLI.Lifecycle

  describe "la columna VRAM" do
    test "pone los MiB del PID de la fila" do
      # El caso normal: el motor esta en la lista de nvidia-smi.
      assert Lifecycle.vram(4321, %{4321 => 12_674}) == "12674 MiB"
    end

    test "un guion cuando ese PID no esta en la lista" do
      # Un modelo de CPU no aparece, y tampoco un PID que ya ha muerto. Un
      # `0 MiB` seria mentira: 0 dice «lo he preguntado y no usa nada».
      assert Lifecycle.vram(9999, %{}) == "-"
      assert Lifecycle.vram(nil, %{}) == "-"
    end

    test "el numero va con su unidad, porque 12674 sin nada no son MiB" do
      assert Lifecycle.vram(1, %{1 => 12_674}) =~ "MiB"
    end

    test "no confunde un PID muerto con uno que no usa GPU" do
      refute Lifecycle.vram(4321, %{}) == "0 MiB"
    end
  end
end
