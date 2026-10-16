defmodule Candil.CLI.StatsTest do
  @moduledoc """
  `candil stats` — el comando que dice si el motor acierta.

  ## Lo que este fichero encontró, medido el 2026-10-16

  El comando estaba declarado en `Candil.CLI`, el módulo existía y la
  telemetría existía, así que el documento de deuda lo daba por hecho. Y
  **reventaba al invocarlo**:

      ** (FunctionClauseError) no function clause matching in Keyword.get/3
        # 1  %{_args: [], quality: false}
        (candil 4.0.0) lib/candil/cli/stats.ex:32: Candil.CLI.Stats.run/1
        (candil 4.0.0) lib/candil/cli.ex:1: Candil.CLI.dispatch_args/1

  Porque Alaja le pasa al handler el mapa de argumentos parseados —`%{_args:
  [], quality: false}`— y `Stats.run/1` lo trataba como si fuera una lista de
  `Keyword`. Los otros seis handlers del CLI ya tenían las dos cláusulas
  (`when is_map` / `when is_list`); este no, y **no tenía test**, que es por lo
  que el fallo llegó a `main` sin que nadie lo viera: `candil stats` no lo corre
  ninguna otra prueba.

  Se prueba por el camino de verdad —`Candil.CLI.main/1`, que es como lo llama
  el escript— y no llamando al handler a mano: el fallo estaba justo en el
  contrato entre los dos, y un test que llame a `run/1` con la forma que le
  apetezca al test no lo habría visto nunca.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Candil.CLI

  describe "candil stats" do
    test "imprime el tribunal y no revienta" do
      salida = capture_io(fn -> assert CLI.main(["stats"]) == :ok end)

      assert salida =~ "DECISIONES DEL ROUTER"
      assert salida =~ "lo resolvio la politica"
    end

    test "con --quality, la tabla por modelo" do
      salida = capture_io(fn -> assert CLI.main(["stats", "--quality"]) == :ok end)

      assert salida =~ "CALIDAD POR MODELO"
    end

    # El mismo contrato, por el otro lado: un llamador que no es Alaja —un test,
    # un host que embebe Candil— pasa una lista de `Keyword`, y las dos formas
    # tienen que valer. Es la convencion de los otros seis handlers del CLI.
    test "el handler acepta las dos formas: mapa y lista" do
      desde_mapa = capture_io(fn -> assert Candil.CLI.Stats.run(%{quality: false}) == :ok end)
      desde_lista = capture_io(fn -> assert Candil.CLI.Stats.run(quality: false) == :ok end)

      assert desde_mapa =~ "DECISIONES DEL ROUTER"
      assert desde_lista =~ "DECISIONES DEL ROUTER"

      con_quality = capture_io(fn -> Candil.CLI.Stats.run(quality: true) end)

      assert con_quality =~ "CALIDAD POR MODELO"
    end
  end
end
