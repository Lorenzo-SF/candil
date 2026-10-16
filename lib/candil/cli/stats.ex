defmodule Candil.CLI.Stats do
  @moduledoc """
  `candil stats` — el tribunal, y con `--quality` la calidad por modelo.

  ## Una capa de nada

  Los dos recuentos estan en `Candil.Telemetry`, que es **framework**: lo puede
  usar cualquiera que tenga Candil como libreria, sin el CLI. Y lo mismo sale por
  `GET /metrics` en el gateway, en JSON.

  Esto es solo `format/1` impreso. El CLI es **una aplicacion** del framework,
  no su sitio donde vive la verdad: si el binario desapareciera, los numeros
  seguirian siendo reales y consultables por otras vias.

  ## Los dos, y por que estan separados

  - `candil stats` → **decidio bien**: que fraccion resolvió la politica
    estatica. El tribunal de `DISENO-MOTOR.md` §10.
  - `candil stats --quality` → **acierto bien**: como se comporta cada modelo.
    Dos señales con retardo distinto, y ninguna es la calidad real.

  Uno es la pregunta de si el motor es bueno. El otro es la de si un modelo
  concreto se esta rompiendo. **Se mezclan en una sola tabla y no se entiende
  ninguna.**
  """

  @doc """
  Imprime el estado del tribunal, o la calidad por modelo con `--quality`.

  ## Las dos formas de `opts`, y por que hacen falta las dos

  Alaja le pasa al handler el **mapa** de argumentos parseados
  (`%{_args: [], quality: false}`), y un llamador que no es Alaja —un test, un
  host que embebe Candil— le pasa una **lista** de `Keyword`. Los otros seis
  handlers del CLI tienen las dos cláusulas; este tenía solo `Keyword.get/3` y
  **reventaba al invocarlo**, medido el 2026-10-16:

      (FunctionClauseError) no function clause matching in Keyword.get/3
        # 1  %{_args: [], quality: false}
        (candil 4.0.0) lib/candil/cli/stats.ex:32: Candil.CLI.Stats.run/1

  Lo pagaba `candil stats` entero: el comando existía, la telemetría existía y
  el comando no se podía correr. Un `@spec` que decía `keyword()` no lo cazó
  porque el que llamaba no leía el `@spec`; lo caza tener un test que lo corra,
  que es lo que faltaba (`test/candil/cli/stats_test.exs`).
  """
  @spec run(map() | keyword()) :: :ok
  def run(opts \\ []) do
    if quality?(opts) do
      IO.puts(Candil.Telemetry.Quality.format(Candil.Telemetry.Quality.snapshot()))
    else
      IO.puts(Candil.Telemetry.Decisions.format(Candil.Telemetry.Decisions.snapshot()))
    end

    :ok
  end

  defp quality?(opts) when is_map(opts), do: Map.get(opts, :quality) == true
  defp quality?(opts) when is_list(opts), do: Keyword.get(opts, :quality) == true
end
