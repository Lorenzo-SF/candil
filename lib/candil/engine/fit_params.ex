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
    with {:ok, fit_binary} <- fetch_binary(engine),
         {:ok, output} <- invoke(fit_binary, engine, model, device) do
      run_with_output(output)
    else
      _ -> :fallback
    end
  end

  @doc """
  Lo que se puede leer de la salida de `llama-fit-params`, sin el binario.

  Es la parte pura del módulo, y está separada por la misma razón que
  `Devices.parse_nvidia/1`: **se prueba contra la salida real, capturada**, que
  es lo único que demuestra que el parser entiende a llama.cpp. Un test con
  una salida inventada prueba que el parser entiende al test.

  Devuelve `{:ok, peso, args}` o `:fallback`.
  """
  @spec run_with_output(binary()) :: {:ok, non_neg_integer(), [String.t()]} | :fallback
  def run_with_output(output) when is_binary(output) do
    args = parse_fitted(output)

    case parse_weight(output, args) do
      nil -> :fallback
      weight when args != [] -> {:ok, weight, args}
      _ -> :fallback
    end
  end

  def run_with_output(_), do: :fallback

  defp fetch_binary(engine) do
    case fit_binary(engine) do
      nil -> :fallback
      path -> {:ok, path}
    end
  end

  defp invoke(fit_binary, engine, model, device) do
    args = compatible_args(engine, model, device)

    case System.cmd(fit_binary, args ++ ["-v"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :fallback
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

    device_args = device_args_for(engine, model, device)

    cache_args = cache_args_from(model.model_args || [])

    base ++ device_args ++ cache_args ++ ["--n-gpu-layers", to_string(layers)]
  end

  defp device_args_for(%Engine{} = engine, %Model{} = model, device) do
    cond do
      engine.cpu or model.gpu_layers == 0 ->
        ["--device", "none"]

      is_integer(device) and device >= 0 ->
        ["--device", "CUDA#{device}", "--split-mode", "none", "--main-gpu", to_string(device)]

      true ->
        []
    end
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

  # El peso es el de la línea `mem=`, que es **lo que el modelo va a ocupar**:
  # pesos + KV cache + compute. Medido el 2026-10-21 con
  # `Qwen3-Coder-30B` y 11518 MiB libres:
  #
  #     | - CUDA0 | 15933 = 11518 + (10452 = 3479 + 6528 + 444) + -6037 |
  #     id=0, n_layer=49, n_part=38, overflow_type=3, mem= 10452 MiB
  #
  # Y el `projected to use` de otra línea es **lo que haría falta si TODO el
  # modelo cupiera en GPU** (19053 MiB en la misma medición). Reservar eso es
  # reservar más que la memoria libre, así que la reserva se rechaza y **el
  # modelo que necesita recorte es justo el que no puede arrancar**. El
  # recorte es lo que permite que un modelo grande quepa en una GPU pequeña.
  #
  # llama.cpp puede escribir VARIAS líneas `mem=` —prueba varias configuraciones
  # y escribe todas—, así que gana la última, y se comprueba contra el `-ngl`
  # de los args ajustados: si hay una línea cuyo `n_layer` coincide con el
  # `-ngl` que va a usar el motor, esa es la buena.
  defp parse_weight(output, fitted) when is_binary(output) do
    candidates =
      Regex.scan(
        ~r/common_params_fit_impl:.*?n_layer=\s*(\d+).*?mem=\s*(\d+)\s*MiB/,
        output
      )
      |> Enum.map(fn [_, layers, mem] ->
        {String.to_integer(layers), String.to_integer(mem)}
      end)

    case candidates do
      [] -> nil
      _ -> pick_weight(candidates, ngl_of(fitted))
    end
  end

  defp pick_weight(candidates, nil), do: candidates |> List.last() |> elem(1)

  defp pick_weight(candidates, ngl) do
    case Enum.find(candidates, fn {layers, _mem} -> layers == ngl end) do
      nil -> candidates |> List.last() |> elem(1)
      {_layers, mem} -> mem
    end
  end

  defp ngl_of([]), do: nil

  defp ngl_of(args) do
    case Enum.find_index(args, &(&1 == "-ngl" or &1 == "--n-gpu-layers")) do
      nil ->
        nil

      index ->
        case Enum.at(args, index + 1) do
          nil ->
            nil

          value ->
            Integer.parse(value)
            |> case do
              {n, ""} -> n
              _ -> nil
            end
        end
    end
  end

  # La última línea de la salida son los args ajustados, y el `-ot` va
  # **entrecomillado**:
  #
  #     -c 131072 -ngl 49 -ot "blk\.11\.ffn_down.*=CPU,…,CPU"
  #
  # Partir esa línea por espacios deja el valor del `-ot` con las comillas
  # DENTRO, y llama-server lo lee como un patrón que empieza por `"` y un
  # buffer type que acaba en `CPU"`:
  #
  #     error while handling argument "-ot": unknown buffer type
  #
  # y el servidor no arranca. Medido el 2026-10-21 en las dos formas: con las
  # comillas no arranca; sin ellas carga y responde.
  #
  # El tokenizador trata el valor entrecomillado como **una unidad**, para que
  # un patrón con espacios dentro no se parta en dos.
  defp parse_fitted(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> []
      line -> tokenize(line)
    end
  end

  defp tokenize(line) do
    Regex.scan(~r/"[^"]*"|\S+/, line)
    |> Enum.map(fn [token] -> unquote_token(token) end)
  end

  defp unquote_token(token) do
    if String.starts_with?(token, "\"") and String.ends_with?(token, "\"") and
         byte_size(token) >= 2 do
      String.slice(token, 1, byte_size(token) - 2)
    else
      token
    end
  end
end
