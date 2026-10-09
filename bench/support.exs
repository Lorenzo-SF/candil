defmodule Bench.Support do
  @moduledoc """
  Lo que los benchmarks necesitan para no medir el aire.

  Un benchmark sin datos reales mide la funcion vacia y da un numero que no
  significa nada. Aqui hay un catalogo de verdad —nombres, ventanas, capacidades—
  y prompts con las tres formas que el router tiene que distinguir: corto,
  largo, y de codigo.
  """

  alias Candil.{Model, Store}

  # El catalogo tiene que Parecerse al de verdad, porque el filtro va a mirar
  # las capacidades. Un catalogo donde todos los modelos hacen lo mismo mide un
  # caso que no existe: el filtro nunca tiene nada que descartar.
  @catalogue [
    {:coder, 131_072, [:chat, :code]},
    {:analyst, 131_072, [:chat, :reasoning]},
    {:verifier, 65_536, [:chat]},
    {:embed, 8_192, [:embeddings]},
    {:designer, 131_072, [:chat, :vision]},
    {:coder_lite, 32_768, [:chat, :code]}
  ]

  @consumer :bench

  @doc "Registra el catalogo de benchmarks en el Store."
  @spec setup!() :: :ok
  def setup! do
    Enum.each(@catalogue, fn {alias, context_size, usage} ->
      model = %Model{
        alias: alias,
        type: :local,
        engine: :llama_cpp,
        context_size: context_size,
        port: 9000 + :erlang.phash2(alias, 900),
        usage: usage,
        model_dir: "/tmp/bench/#{alias}",
        filename: "#{alias}.gguf"
      }

      # `register_model/1` revalida y sobreescribe: da igual si ya estaba.
      :ok = Store.register_model(model)
    end)

    :ok
  end

  @doc "El consumer de los benchmarks, con su pin."
  @spec consumer() :: atom()
  def consumer, do: @consumer

  @doc "Une los mensajes en un texto, como los mandan de verdad."
  @spec prompt(String.t()) :: [map()]
  def prompt(text), do: [%{role: "user", content: text}]

  @doc "El prompt corto: el caso de un prompt de verdad."
  @spec corto() :: [map()]
  def corto, do: prompt("arregla este bug de Elixir")

  @doc "El prompt largo: donde el presupuesto de contexto se nota."
  @spec largo() :: [map()]
  def largo do
    cuerpo = String.duplicate("frase de relleno sobre el mismo tema. ", 400)
    prompt("Repite esto sin cambiar nada:\n\n" <> cuerpo)
  end

  @doc "El prompt de codigo: el que las reglas tienen que reconocer."
  @spec codigo() :: [map()]
  def codigo do
    prompt("""
    refactoriza esta funcion, el test falla en el modulo de compile:

        def foo(a, b), do: a + b
    """)
  end

  @doc "Todos los prompts, para el benchmark que compara los tres."
  @spec prompts() :: [{String.t(), [map()]}]
  def prompts, do: [{"corto", corto()}, {"largo", largo()}, {"codigo", codigo()}]
end
