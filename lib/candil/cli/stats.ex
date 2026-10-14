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
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    if Keyword.get(opts, :quality, false) do
      IO.puts(Candil.Telemetry.Quality.format(Candil.Telemetry.Quality.snapshot()))
    else
      IO.puts(Candil.Telemetry.Decisions.format(Candil.Telemetry.Decisions.snapshot()))
    end

    :ok
  end
end
