defmodule Candil.Engine.FitParams do
  @moduledoc """
  Pregunta a `llama-fit-params` cuánta VRAM va a reservar un modelo **antes**
  de arrancarlo, y qué args ajustados necesita para que quepa.
  """

  alias Candil.Engine
  alias Candil.Model

  @spec run(Engine.t(), Model.t(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer(), [String.t()]} | :fallback
  def run(%Engine{} = engine, %Model{} = model, device) do
    case fit_binary(engine) do
      nil ->
        :fallback

      fit_binary ->
        args = compatible_args(engine, model, device)

        case System.cmd(fit_binary, args ++ ["-v"], stderr_to_stdout: true) do
          {output, 0} ->
            case {parse_weight(output), parse_fitted(output)} do
              {w, fitted} when is_integer(w) and fitted != [] ->
                {:ok, w, fitted}

              _ ->
                :fallback
            end

          _ ->
            :fallback
        end
    end
  end

  defp fit_binary(%Engine{} = engine) do
    path = Engine.binary_path(engine)
    candidate = Path.join(Path.dirname(path), "llama-fit-params")
    if File.exists?(candidate), do: candidate, else: nil
  end

  defp compatible_args(%Engine{} = engine, %Model{} = model, device) do
    model_path = Path.join(model.model_dir, model.filename)
    context = to_string(model.context_size || 4096)
    layers = if engine.cpu or model.gpu_layers == 0, do: 0, else: model.gpu_layers

    base = ["--model", model_path, "--ctx-size", context]

    device_args =
      cond do
        engine.cpu or model.gpu_layers == 0 ->
          ["--device", "none"]

        is_integer(device) and device >= 0 ->
          ["--device", "CUDA#{device}", "--split-mode", "none", "--main-gpu", to_string(device)]

        true ->
          []
      end

    cache_args = cache_args_from(model.model_args || [])

    base ++ device_args ++ cache_args ++ ["--n-gpu-layers", to_string(layers)]
  end

  defp cache_args_from(args) when is_list(args) do
    args
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      ["--cache-type-k", v] -> ["--cache-type-k", v]
      ["--cache-type-v", v] -> ["--cache-type-v", v]
      ["-ctk", v] -> ["--cache-type-k", v]
      ["-ctv", v] -> ["--cache-type-v", v]
      _ -> []
    end)
  end

  defp cache_args_from(_), do: []

  defp parse_weight(output) when is_binary(output) do
    case Regex.run(~r/projected to use (\d+) MiB/, output) do
      [_, n] ->
        case Integer.parse(n) do
          {v, ""} when v > 0 -> v
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_fitted(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> []
      line -> String.split(line, ~r/\s+/, trim: true)
    end
  end
end
