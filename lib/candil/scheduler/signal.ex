defmodule Candil.Scheduler.Signal do
  @moduledoc """
  La señal que un modelo emite al scheduler: cuánto cuesta, en las unidades
  del dispositivo donde va a correr.

  Dos capas, misma forma, distintas unidades (07-local-aparcado §4):

  - `:local` — megas (capacidad física) y segundos (tiempo de arranque).
  - `:remote` — euros (coste) y rpm (cuota).

  El scheduler no sabe qué es una GPU ni qué es un euro: solo ve números.
  Quien traduce el modelo a señal es este módulo.
  """

  @type t :: %__MODULE__{
          kind: :local | :remote,
          size_mb: non_neg_integer() | nil,
          startup_s: non_neg_integer() | nil,
          cost_eur: float() | nil,
          rpm: non_neg_integer() | nil
        }

  defstruct kind: :local,
            size_mb: nil,
            startup_s: nil,
            cost_eur: nil,
            rpm: nil

  @doc """
  Señal de un modelo local. `size_mb` viene del modelo si lo declara
  (`Model.vram_mb`), o se estima del contexto (4 MB por cada 1024 tokens de
  ventana, que es el orden de magnitud de un KV cache en q8). `startup_s`
  es una estimación conservadora: 30 s para cualquier modelo local.
  """
  @spec for_local(Candil.Model.t()) :: t()
  def for_local(%Candil.Model{} = model) do
    size_mb = model.vram_mb || estimate_size_mb(model)

    %__MODULE__{
      kind: :local,
      size_mb: size_mb,
      startup_s: 30
    }
  end

  @doc """
  Señal de un modelo remoto. `cost_eur` y `rpm` vienen del provider.
  """
  @spec for_remote(Candil.Model.t(), map()) :: t()
  def for_remote(%Candil.Model{} = _model, provider) when is_map(provider) do
    %__MODULE__{
      kind: :remote,
      cost_eur: Map.get(provider, :cost_eur),
      rpm: Map.get(provider, :rpm)
    }
  end

  @doc "Los megas que ocupa, o 0 si no se sabe."
  @spec size_mb(t()) :: non_neg_integer()
  def size_mb(%__MODULE__{size_mb: nil}), do: 0
  def size_mb(%__MODULE__{size_mb: n}) when is_integer(n) and n >= 0, do: n

  defp estimate_size_mb(%Candil.Model{context_size: ctx}) when is_integer(ctx) and ctx > 0 do
    # ~4 MB por 1024 tokens de ventana: orden de magnitud del KV cache en q8.
    div(ctx, 1024) * 4
  end

  defp estimate_size_mb(_), do: 0
end
