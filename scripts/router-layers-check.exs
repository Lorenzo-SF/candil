# MEDIR las dos capas del enrutado en la maquina del dueno.
#
#     mix run scripts/router-layers-check.exs
#
# Esto NO es un test, y la diferencia no es de estilo. Un test comprueba que la
# capa hace lo que dice; esto comprueba si lo que dice SIRVE. Las dos preguntas
# necesitan maquinas distintas: la primera, un portatil sin GPU; la segunda, un
# modelo de verdad y las preguntas que le hacen de verdad.
#
# ────────────────────────────────────────────────────────────────────────────
# QUE SE MIDE AQUI, Y QUE NO
# ────────────────────────────────────────────────────────────────────────────
#
#   SECCION 1 · el MECANISMO, con un clasificador y un embedder de mentira.
#             Funciona hoy, sin GPU y sin descargar nada: que la capa filtra,
#             que devuelve `:miss` cuando no debe, y que el bucle revienta.
#
#   SECCION 2 · lo UNICO que no se puede testear: si un LLM real clasifica
#             bien, y si un embedder real da similitudes que sirvan. Eso
#             necesita TUS modelos y TUS prompts, asi que hay que poner las dos
#             lineas marcadas abajo y mirar una tabla.
#
# Si la seccion 2 no dice nada util, la seccion 1 seguira verde. Esa es
# exactamente la razon de que este script exista, y de que el `@moduledoc` de
# `test/candil/router/scorer_layers_test.exs` diga que sus tests comprueban el
# MECANISMO y no la UTILIDAD.
#
# ────────────────────────────────────────────────────────────────────────────
# QUE TIENE QUE IMPRIMIR PARA QUE LA MEDICION SIRVA
# ────────────────────────────────────────────────────────────────────────────
#
#   1. Las ocho lineas de la seccion 1, con el ranking o el motivo de cada
#      caso. Un `:miss` ahi es el resultado correcto.
#
#   2. En la seccion 2, una fila por prompt con el ranking REAL y cual gano. Un
#      0.83 no dice nada: la pregunta es si el que gana es el que tu habrias
#      puesto a mano.
#
#   3. El RECUENTO de aciertos al final. Ese numero es el que decide si la
#      capa se enciende. Por debajo del 90% en la maquina real, la conclusion
#      NO es «cambia el clasificador»: es que las `description` de los modelos
#      —el dato de entrada— no distinguen, y un embedder no arregla un
#      catalogo que no sabe distinguir.
#
# ────────────────────────────────────────────────────────────────────────────
# LO QUE ESTA DECIDIDO Y LO QUE NO
# ────────────────────────────────────────────────────────────────────────────
#
# Ya estan escritos: los umbrales `embedding_threshold` (0.55) y
# `confidence_threshold` (0.70) de `[router]`, y el hecho de que las capas
# FILTRAN y no ordenan. NO esta decidido el embedder por defecto ni el
# clasificador por defecto, y mientras no lo haya la seccion 2 no se puede
# ejecutar sin las dos lineas de abajo.
alias Candil.Embeddings.Adapter
alias Candil.Engine
alias Candil.Model
alias Candil.Router.Classifier
alias Candil.Router.{Cache, Consumer, Scorer}
alias Candil.Store

defmodule Informe do
  @moduledoc "Imprimir, y poco mas."

  def seccion(titulo), do: IO.puts("\n#{String.duplicate("═", 70)}\n#{titulo}")

  def linea(etiqueta, valor),
    do: IO.puts("  #{String.pad_trailing(etiqueta, 18)} #{valor}")

  @doc "Un ranking, un `:miss` o un error, en una linea que se puede leer."
  def valor({:ok, ranked, _reason}),
    do: Enum.map_join(ranked, "  ", &"#{elem(&1, 0)}=#{Float.round(elem(&1, 1), 3)}")

  def valor(:miss), do: ":miss  (la capa no existe, o no sabe)"
  def valor({:error, motivo}), do: "ERROR  #{inspect(motivo)}"
end

defmodule Mecanica do
  @moduledoc "Clasificador y embedder de mentira. Comprueban el mecanismo, no la calidad."

  defmodule Etiquetas do
    @behaviour Classifier

    @impl true
    def classify(messages, _opts) do
      text = messages |> Scorer.prompt_text() |> String.downcase()

      difficulty =
        cond do
          String.contains?(text, "prueba") -> :deep
          String.contains?(text, "midiendo") -> :normal
          true -> :fast
        end

      {:ok, %{difficulty: difficulty, confidence: 0.9, why: "palabras de prueba"}}
    end

    @impl true
    def name, do: :etiquetas

    @impl true
    def enabled?(_opts), do: true
  end

  defmodule Desconocido do
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts), do: {:error, :unknown}
    @impl true
    def name, do: :desconocido
    @impl true
    def enabled?(_opts), do: true
  end

  defmodule Ciclico do
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts) do
      Candil.Router.route([%{role: "user", content: "hola"}], candidates: [:plano])
      {:ok, %{difficulty: :normal, confidence: 1.0, why: "no se llega aqui"}}
    end

    @impl true
    def name, do: :ciclico
    @impl true
    def enabled?(_opts), do: true
  end

  defmodule Fijo do
    @moduledoc "Embedder de mentira: dos dimensiones, y un vector por texto."
    @behaviour Adapter

    @vectors %{
      "hola" => [1.0, 0.0],
      "escribe y arregla codigo" => [1.0, 0.0],
      "razona y demuestra" => [0.0, 1.0],
      "charla y resume" => [0.0, 1.0]
    }

    @impl true
    def embed(texts, _opts), do: {:ok, Enum.map(texts, &Map.get(@vectors, &1, [0.0, 0.0]))}

    @impl true
    def dimension(_opts), do: 2

    @impl true
    def supports?(:text), do: true
    def supports?(_otro), do: false
  end

  defmodule MalasDimensiones do
    @moduledoc "Un embedder que miente sobre su propia dimension."
    @behaviour Adapter

    @impl true
    def embed(texts, _opts), do: {:ok, Enum.map(texts, fn _t -> [1.0, 0.0, 0.0, 0.0] end)}

    @impl true
    def dimension(_opts), do: 2

    @impl true
    def supports?(:text), do: true
    def supports?(_otro), do: false
  end
end

# ────────────────────────────────────────────────────────────────────────────
# SECCION 1 · el mecanismo
# ────────────────────────────────────────────────────────────────────────────

hola = [%{role: "user", content: "hola"}]
prueba = [%{role: "user", content: "esto es una prueba dura"}]

Cache.flush()
Consumer.unpin(:medicion)
Scorer.flush_vector_cache()

# ESTE SCRIPT TIENE QUE SER EL DUENO DEL CATALOGO. `mix run` hidrata el toml
# real en el Store antes de ejecutar una linea de aqui, y un modelo de mas
# cambia los tres casos de abajo sin que se note. Por eso se vacia y se dice.
# `deregister_model/1` toma el **alias**, no el modelo. Pasarle el struct es
# un FunctionClauseError, y este script se Clarenceo entero en el primer
# `mix run` de verdad. Un script que no se ha ejecutado nunca no es un script.
importados = Store.list_models()
Enum.each(importados, &Store.deregister_model(&1.alias))
:ok = Store.register_engine(%Engine{alias: :llama_cpp, binary: "llama-server"})

alta = fn alias, usage, description ->
  :ok =
    Store.register_model(%Model{
      alias: alias,
      type: :local,
      engine: :llama_cpp,
      usage: usage,
      description: description,
      model_dir: "/models",
      filename: "#{alias}.gguf"
    })
end

alta.(:coder, [:chat, :code], "escribe y arregla codigo")
alta.(:verifier, [:chat, :reasoning], "razona y demuestra")
alta.(:plano, [:chat], "charla y resume")
alta.(:embed, [:embeddings], "convierte texto en vectores")
# Sin descripcion a proposito: es el caso de la capa de embeddings que devuelve
# `:miss` sin llamar al embedder, y el que mas se va a repetir en la maquina
# real mientras nadie escriba las descripciones.
alta.(:sin_desc, [:chat], nil)

:ok = Classifier.register(:etiquetas, Mecanica.Etiquetas)
:ok = Classifier.register(:desconocido, Mecanica.Desconocido)
:ok = Classifier.register(:ciclico, Mecanica.Ciclico)
:ok = Adapter.register(:fijo, Mecanica.Fijo)
:ok = Adapter.register(:malos, Mecanica.MalasDimensiones)

Informe.seccion("SECCION 1 · el mecanismo, con clasificadores de mentira")
Informe.linea("catalogo", inspect(Enum.map(Store.list_models(), & &1.alias)))

score = fn messages, candidates, layer, settings ->
  Informe.valor(Scorer.score(messages, candidates, layer, settings))
end

Informe.linea(":deep, hay", score.(prueba, [:coder, :verifier], :llm, %{classifier: :etiquetas}))
Informe.linea(":deep, no hay", score.(prueba, [:coder, :plano], :llm, %{classifier: :etiquetas}))
Informe.linea(":fast", score.(hola, [:coder, :verifier], :llm, %{classifier: :etiquetas}))
Informe.linea(":unknown", score.(hola, [:coder, :verifier], :llm, %{classifier: :desconocido}))
Informe.linea("sin clasificador", score.(hola, [:coder, :verifier], :llm, %{}))
Informe.linea("sin embedder", score.(hola, [:coder, :verifier], :embedding, %{}))
Informe.linea("embedder que no", score.(hola, [:coder], :embedding, %{embedder: :no_existe}))

Informe.linea("sin descripcion", score.(hola, [:sin_desc], :embedding, %{embedder: :fijo}))

Informe.linea("dimensiones", score.(hola, [:coder], :embedding, %{embedder: :malos}))
Informe.linea("embeddings", score.(hola, [:coder, :verifier], :embedding, %{embedder: :fijo}))

bucle =
  try do
    Scorer.score(hola, [:coder], :llm, %{classifier: :ciclico})
    "NO ha reventado — eso es un bucle infinito esperando a que caiga el stack"
  rescue
    e -> "reventado: " <> (e.message |> String.split("\n") |> hd())
  end

Informe.linea("el bucle", bucle)

# ────────────────────────────────────────────────────────────────────────────
# SECCION 2 · LA MEDICION. Pon aqui TUS dos modulos.
# ────────────────────────────────────────────────────────────────────────────

Informe.seccion("SECCION 2 · la medicion, con TUS modelos")

defmodule Medir do
  @moduledoc """
  Los prompts de verdad, con el modelo que TU quieres que gane en cada uno.

  La segunda elemento de cada tupla es la respuesta, escrita por la persona. El
  ranking lo pone la maquina; si el que gana no es el de aqui, la capa no esta
  funcionando para ti. Y bajar el umbral con estos numeros delante es la unica
  forma de tocarlo sin adivinar.
  """

  @prompts [
    {"refactoriza este modulo de Elixir y dime por que esta roto", :coder},
    {"demuestrame que este algoritmo termina", :verifier},
    {"resumeme este texto en tres frases", :plano},
    {"escribe un test para este caso", :coder},
    {"compara estas dos opciones y di cual prefieres", :verifier}
  ]

  def prompts, do: @prompts
end

defmodule MiEmbedder do
  @moduledoc """
  REEMPLAZA ESTE MODULO por el tuyo, o pon el nombre del tuyo en la linea de
  `Adapter.register/2` de mas abajo. Sin esto la seccion 2 no mide nada: mide un
  vector de mentira con forma de vector.
  """
  @behaviour Adapter

  @impl true
  def embed(_texts, _opts), do: {:error, :aun_no_conectado}

  @impl true
  def dimension(_opts), do: 0

  @impl true
  def supports?(:text), do: true
  def supports?(_otro), do: false
end

defmodule MiClasificador do
  @moduledoc "REEMPLAZA ESTE MODULO por el tuyo. Mismo contrato, y las tres salidas."
  @behaviour Classifier

  @impl true
  def classify(_messages, _opts), do: {:error, :aun_no_conectado}

  @impl true
  def name, do: :mio

  @impl true
  def enabled?(_opts), do: true
end

:ok = Adapter.register(:mi_embedder, MiEmbedder)
:ok = Classifier.register(:mi_clasificador, MiClasificador)

IO.puts("""

  La seccion 2 usa #{inspect(MiEmbedder)} y #{inspect(MiClasificador)}, que ahora
  mismo son de mentira. Para que mida algo, pon aqui los modulos reales:

    · uno que cumpla `Candil.Embeddings.Adapter` —embed/2, dimension/1, supports?/1—
    · uno que cumpla `Candil.Router.Classifier`  —classify/2, name/0, enabled?/1—

  y dale a `mix run scripts/router-layers-check.exs` otra vez. Este script saca
  una fila por prompt con el ranking real y cuenta cuantos llegaron al modelo
  que tu esperabas. Ese recuento, y no el 0.83 de una similitud, es lo que
  decide si la capa se enciende.
""")

IO.puts("  #{String.pad_trailing("prompt", 54)} #{String.pad_trailing("esperado", 10)} ranking")

aciertos =
  Enum.reduce(Medir.prompts(), 0, fn {prompt, esperado}, cuenta ->
    resultado =
      Scorer.score([%{role: "user", content: prompt}], [:coder, :verifier, :plano], :embedding, %{
        embedder: :mi_embedder
      })

    ganador =
      case resultado do
        {:ok, [{alias, _score} | _], _reason} -> alias
        _ -> :ninguno
      end

    IO.puts(
      "  #{String.pad_trailing(prompt, 54)} #{String.pad_trailing(inspect(esperado), 10)} #{Informe.valor(resultado)}"
    )

    if ganador == esperado, do: cuenta + 1, else: cuenta
  end)

total = length(Medir.prompts())

IO.puts("""

  RECUENTO: #{aciertos}/#{total} de los prompts llegaron al modelo que tu esperabas.

  Con un embedder de mentira ese numero no significa nada, y por eso esta aqui
  y no en un test. Cuando el embedder sea el tuyo:

    · por encima del 90%: la capa sirve, y lo que falta es bajar
      `embedding_threshold` hasta donde empieza a fallar, mirandolo en esta tabla.
    · por debajo del 90%: NO cambies el umbral. Suele estar en las `description`
      de los modelos —que son el dato de entrada, y las escribio alguien sin
      pensar en la comparacion— y en tener dos modelos que dicen casi lo mismo.
      Un embedder no arregla un catalogo que no distingue.
""")
