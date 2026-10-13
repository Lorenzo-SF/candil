defmodule Candil.CLI.Stats do
  @moduledoc """
  `candil stats` — el tribunal, en una terminal.

  ## Una capa de nada

  Todo el conteo esta en `Candil.Telemetry.Decisions`, que es **framework**: lo
  puede usar cualquiera que tenga Candil como libreria, sin el CLI. Y el mismo
  dato sale por `GET /metrics` en el gateway, en JSON.

  Esto es solo `format/1` impreso. El CLI es **una aplicacion** del framework,
  no su sitio donde vive la verdad: si el binario desapareciera, el numero
  seguiria siendo real y consultable por otras dos vias.
  """

  @doc """
  Imprime el estado del tribunal.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(Candil.Telemetry.Decisions.snapshot()))
    else
      IO.puts(Candil.Telemetry.Decisions.format(Candil.Telemetry.Decisions.snapshot()))
    end

    :ok
  end
end
