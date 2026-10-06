defmodule Candil.CLI.Router do
  @moduledoc """
  `candil route`, `candil pin`, `candil unpin`.

  Existe por el motivo mas simple del mundo: **el sistema estatico se puede
  equivocar, y hace falta una salida que no sea apagarlo.** Sin override, un
  fallo de las reglas es un callejon sin salida y obliga a acertar a la
  primera; con override, fallaste, lo fuerzas, ves que paso, y arreglas la
  regla. Es lo que permite ir mejorando el estatico sin miedo.

  El forzado **se dice**. `Decision.reason` lleva el motivo, incluido el
  forzado: un router que calla como decidio es un router que hay que debugar
  apagandolo.
  """

  alias Alaja.Output
  alias Candil.Router
  alias Candil.Router.{Cache, Consumer}

  @doc """
  `candil route "<prompt>" [--model X] [--consumer Y]`.
  """
  @spec run(map() | keyword()) :: :ok
  def run(opts \\ []) do
    text = get(opts, :prompt)

    if blank?(text) do
      Output.print_error("falta el prompt: candil route \"que le pregunto a quien\"")
      :error
    else
      decide(text, get(opts, :model), get(opts, :consumer))
    end
  end

  defp decide(text, model, consumer) do
    opts =
      [consumer: normalize_consumer(consumer)]
      |> then(fn opts -> if model, do: [{:force_model, to_alias(model)} | opts], else: opts end)

    case Router.route([%{role: "user", content: text}], opts) do
      {:ok, decision} ->
        show(decision)
        :ok

      {:error, error} ->
        Output.print_error("no se pudo decidir: #{explain(error)}")
        :error
    end
  end

  defp show(decision) do
    Output.print_success("-> #{decision.model_alias}")
    Output.print("   estrategia  #{decision.strategy}")
    Output.print("   score       #{decision.score}")
    Output.print("   confianza   #{decision.confidence}")
    Output.print("   reason      #{decision.reason}")

    if decision.degraded != [] do
      Output.print_warning("   NO se miraron: #{Enum.join(decision.degraded, ", ")}")
    end

    unless decision.alternatives == [] do
      Output.print("   otras       #{inspect(decision.alternatives)}")
    end

    :ok
  end

  defp explain(%{reason: reason, context: context}) do
    hint = if is_map(context), do: context[:hint], else: nil
    base = "#{reason}#{if hint, do: " — #{hint}", else: ""}"
    candidates = if is_map(context), do: context[:candidates], else: nil
    if candidates, do: "#{base} (puedes usar: #{Enum.join(candidates, ", ")})", else: base
  end

  defp explain(other), do: inspect(other)

  @doc """
  `candil pin [model]` — sin argumentos, dice que hay pineado y a quien.
  """
  @spec pin(map() | keyword()) :: :ok
  def pin(opts \\ []) do
    consumer = normalize_consumer(get(opts, :consumer))

    case get(opts, :model) do
      nil ->
        case Consumer.pinned(consumer) do
          {:ok, alias} ->
            Output.print("pin de #{consumer}: #{alias}")
            :ok

          :error ->
            Output.print("pin de #{consumer}: ninguno")
            :ok
        end

      model ->
        case Router.pin(consumer, to_alias(model)) do
          :ok ->
            Output.print_success("pin de #{consumer}: #{to_alias(model)}")
            :ok

          {:error, error} ->
            Output.print_error("no se pudo pinear: #{explain(error)}")
            :error
        end
    end
  end

  @doc """
  `candil unpin`.
  """
  @spec unpin(map() | keyword()) :: :ok
  def unpin(opts \\ []) do
    consumer = normalize_consumer(get(opts, :consumer))
    :ok = Router.unpin(consumer)
    Output.print_success("pin de #{consumer}: ninguno")
    Cache.flush()
    :ok
  end

  defp normalize_consumer(nil), do: :default

  defp normalize_consumer(name) do
    String.downcase(to_string(name)) |> String.replace("-", "_") |> String.to_atom()
  end

  defp to_alias(name), do: name |> to_string() |> String.to_atom()

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(to_string(text)) == ""

  defp get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
end
