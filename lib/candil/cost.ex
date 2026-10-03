defmodule Candil.Cost do
  @moduledoc """
  Cost estimation for LLM API usage.

  Prices are stored as USD per 1M tokens for `(input, output)`. Only
  models with well-known pricing are listed; unknown models return
  `:unknown`.

  ## Example

      iex> Candil.Cost.estimate("gpt-4o", 1000, 500)
      {:ok, 0.00775}

      iex> Candil.Cost.estimate("unknown-model", 1000, 500)
      :unknown
  """

  alias Candil.Telemetry

  # Loaded from priv/pricing.exs. `@pricing` used to be a literal map in the
  # module, which meant a price change was a code change, and a table of 2024
  # numbers in 2026 is a lie with a version number on it.
  @external_resource "priv/pricing.exs"
  @pricing Path.join([__DIR__, "..", "..", "priv", "pricing.exs"])
           |> Code.eval_file()
           |> elem(0)
           |> Map.new()

  @doc "Estimates the USD cost for a model and token counts."
  @spec estimate(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | :unknown
  def estimate(model, input_tokens, output_tokens) do
    case Map.get(@pricing, normalize(model)) do
      nil ->
        :unknown

      {in_cost, out_cost} ->
        cost =
          input_tokens / 1_000_000 * in_cost + output_tokens / 1_000_000 * out_cost

        {:ok, Float.round(cost, 6)}
    end
  end

  @doc """
  Estimate cost for a `(provider, model, input_tokens, output_tokens)`
  tuple. Returns `{:ok, cost_usd}` on success, `:unknown` if the
  model is not in the pricing table, or `{:error, reason}` if the
  inputs are invalid.

  Emits `[:candil, :cost, :estimate]` telemetry on every call (even
  for unknown models, with `cost_usd: 0.0`).
  """
  @spec estimate(atom() | String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | :unknown | {:error, term()}
  def estimate(provider, model, input_tokens, output_tokens)
      when is_atom(provider) or is_binary(provider) do
    cond do
      not is_integer(input_tokens) or input_tokens < 0 ->
        {:error, :invalid_input_tokens}

      not is_integer(output_tokens) or output_tokens < 0 ->
        {:error, :invalid_output_tokens}

      true ->
        case estimate(model, input_tokens, output_tokens) do
          {:ok, cost} ->
            Telemetry.emit_cost(provider, model, input_tokens, output_tokens, cost)
            {:ok, cost}

          :unknown ->
            Telemetry.emit_cost(provider, model, input_tokens, output_tokens, 0.0)
            :unknown
        end
    end
  end

  @doc "Returns the model names with known pricing."
  @spec known_models() :: [String.t()]
  def known_models, do: Map.keys(@pricing)

  @doc """
  Formats a USD price as a human-readable string.

  Examples:
    * 0.00775 → "$0.0078"
    * 1.50    → "$1.50"
    * 1500.0  → "$1.5K"
    * 1_500_000 → "$1.5M"

  Negative prices are formatted with a leading minus sign.

  ## Examples

      iex> Candil.Cost.format_price(0.0075)
      "$0.0075"

      iex> Candil.Cost.format_price(1500.0)
      "$1.5K"
  """
  @spec format_price(float()) :: String.t()
  def format_price(price) when is_number(price) do
    cond do
      price >= 1_000_000 -> "$#{Float.round(price / 1_000_000, 2)}M"
      price >= 1_000 -> "$#{Float.round(price / 1_000, 2)}K"
      price >= 1 -> "$#{Float.round(price, 2)}"
      price >= 0.01 -> "$#{Float.round(price, 4)}"
      true -> "$#{Float.round(price, 6)}"
    end
  end

  def format_price(price) when is_integer(price) do
    format_price(price / 1.0)
  end

  @spec normalize(String.t()) :: String.t()
  defp normalize(model) do
    # Strip any provider prefix (e.g. "openai/gpt-4o" → "gpt-4o")
    String.split(model, "/") |> List.last() |> String.downcase()
  end
end
