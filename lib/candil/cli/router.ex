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

  alias Alaja.Printer, as: Say
  alias Candil.Router
  alias Candil.Router.{Cache, Consumer}

  @doc """
  `candil route "<prompt>" [--model X] [--consumer Y]`.
  """
  @spec run(map() | keyword()) :: :ok
  def run(opts \\ []) do
    text = get(opts, :prompt)

    if blank?(text) do
      Say.print_error("falta el prompt: candil route \"que le pregunto a quien\"")
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
        Say.print_error("no se pudo decidir: #{explain(error)}")
        :error
    end
  end

  defp show(decision) do
    Say.print_success("-> #{decision.model_alias}")
    Say.print("   estrategia  #{decision.strategy}")
    Say.print("   score       #{decision.score}")
    Say.print("   confianza   #{decision.confidence}")
    Say.print("   reason      #{decision.reason}")

    if decision.degraded != [] do
      Say.print_warning("   NO se miraron: #{Enum.join(decision.degraded, ", ")}")
    end

    unless decision.alternatives == [] do
      Say.print("   otras       #{inspect(decision.alternatives)}")
    end

    :ok
  end

  # `Router.route/2` NO devuelve `%Candil.Error{}`: devuelve atomos y tuplas
  # (`{:unknown_model, alias}`). Este `explain/1` estaba escrito para una forma
  # que la funcion no produce nunca, y dialyzer lo marco como
  # `pattern_match`: la rama es codigo muerto.
  #
  # Se reescribe contra la forma real, y ahora cada error dice ALGO UTIL en vez
  # de imprimir un mapa vacio.
  defp explain(:no_models_for_consumer) do
    "este consumer no tiene modelos. Ponlos en [consumer.<nombre>] models, " <>
      "o quita model_default de [general]"
  end

  defp explain({:unknown_model, alias}) do
    "ese modelo no existe en el catalogo: #{alias}"
  end

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
            Say.print("pin de #{consumer}: #{alias}")
            :ok

          :error ->
            Say.print("pin de #{consumer}: ninguno")
            :ok
        end

      model ->
        case Router.pin(consumer, to_alias(model)) do
          :ok ->
            Say.print_success("pin de #{consumer}: #{to_alias(model)}")
            :ok

          {:error, error} ->
            Say.print_error("no se pudo pinear: #{explain(error)}")
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
    Say.print_success("pin de #{consumer}: ninguno")
    Cache.flush()
    :ok
  end

  defp normalize_consumer(nil), do: :default

  defp normalize_consumer(name) do
    # `to_existing_atom/1` y no `to_atom/1`: el alias viene de la linea de
    # comandos, y crear atomos desde ahi es una denegacion de servicio que uno
    # mismo se cura. Si el alias no existe en el catalogo, el router lo dira
    # al no encontrarlo entre los candidatos.
    String.downcase(to_string(name))
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  end

  # `to_existing_atom` y no `to_atom`: el alias viene de la linea de comandos y
  # crear atomos desde ahi es una denegacion de servicio que uno mismo se
  # cura. Si el alias no existe en el catalogo, lo dira el router al no
  # encontrarlo entre los candidatos.
  defp to_alias(name), do: name |> to_string() |> String.to_existing_atom()

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(to_string(text)) == ""

  defp get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
end
