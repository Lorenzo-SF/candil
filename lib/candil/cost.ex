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

  # Pricing table — USD per 1M tokens, format: {input_per_1m, output_per_1m}
  @pricing %{
    # OpenAI
    "gpt-4o" => {2.50, 10.00},
    "gpt-4o-2024-08-06" => {2.50, 10.00},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4o-mini-2024-07-18" => {0.15, 0.60},
    "gpt-4-turbo" => {10.00, 30.00},
    "gpt-4-turbo-2024-04-09" => {10.00, 30.00},
    "gpt-4" => {30.00, 60.00},
    "gpt-3.5-turbo" => {0.50, 1.50},
    "o1-preview" => {15.00, 60.00},
    "o1-mini" => {3.00, 12.00},
    # Anthropic
    "claude-3-5-sonnet-20241022" => {3.00, 15.00},
    "claude-3-5-sonnet-latest" => {3.00, 15.00},
    "claude-3-5-haiku-20241022" => {0.80, 4.00},
    "claude-3-5-haiku-latest" => {0.80, 4.00},
    "claude-3-opus-20240229" => {15.00, 75.00},
    "claude-3-sonnet-20240229" => {3.00, 15.00},
    "claude-3-haiku-20240307" => {0.25, 1.25},
    # Local (free)
    "llama3" => {0.0, 0.0},
    "llama3.1" => {0.0, 0.0},
    "llama3.2" => {0.0, 0.0},
    "llama3.3" => {0.0, 0.0},
    "mistral" => {0.0, 0.0},
    "qwen2" => {0.0, 0.0},
    "gemma2" => {0.0, 0.0}
  }

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
            Candil.Telemetry.emit_cost(provider, model, input_tokens, output_tokens, cost)
            {:ok, cost}

          :unknown ->
            Candil.Telemetry.emit_cost(provider, model, input_tokens, output_tokens, 0.0)
            :unknown
        end
    end
  end

  @doc "Returns the model names with known pricing."
  @spec known_models() :: [String.t()]
  def known_models, do: Map.keys(@pricing)

  @spec normalize(String.t()) :: String.t()
  defp normalize(model) do
    # Strip any provider prefix (e.g. "openai/gpt-4o" → "gpt-4o")
    String.split(model, "/") |> List.last() |> String.downcase()
  end
end
