defmodule Candil.Router.ClassifierTest do
  @moduledoc """
  Qué clasificador decide, y quién lo elige.

  ## El hueco exacto

  `Scorer` declara `@type layer :: :rule | :embedding | :llm` y **solo tiene `:rule`**. Las otras
  dos capas no existen, y `DecisionEngine` ya las llama:

  ```elixir
  _alias -> Scorer.score(messages, candidates, :llm, settings)
  ```

  `Scorer.score/4` no tiene clausula para `:llm` ni para `:embedding`, asi que
  las dos caen en `:miss`. **La arquitectura de capas esta pensada y el
  clasificador no esta escrito.** Sin el, el router solo tiene palabras clave.

  ## Y por qué un behaviour y no una funcion

  Por lo mismo que `Provider`, `Chunker` y `Embeddings`: la capa es **codigo** y
  la activacion es un **valor** en `[router]`. Un clasificador propio —un
  modelo local, un clasificador de reglas del proyecto, uno afinado para tu
  dominio— se registra y decide, sin recompilar Candil.

  ## Lo que un clasificador NO es

  **No elige el modelo.** Dice *how* de dificil es esto, y la afinidad y el
  filtro eligen el modelo. Un clasificador que devuelve un alias se ha
  que puede responder a la misma pregunta dos veces, con dos respuestas distintas.
  """

  use ExUnit.Case, async: false

  alias Candil.Router.Classifier

  defmodule Tags do
    @moduledoc """
    Un clasificador de mentira que devuelve dificultad segun palabras, y que
    ademas **declara cuanto se equivoca** —que es lo que hace util a un
    clasificador de verdad.
    """
    @behaviour Classifier

    @impl true
    # Recibe MENSAJES, no texto suelto: es lo que el router tiene. Aplanarlos
    # es cosa de quien clasifica, porque cada clasificador decide que le
    # importa —una herramienta de embeddings no lee igual que unas reglas.
    def classify(messages, opts) do
      text = messages |> messages_to_text() |> String.downcase()

      difficulty =
        cond do
          String.contains?(text, "refactor") -> :deep
          String.contains?(text, "por que") -> :normal
          true -> :fast
        end

      _ = opts

      {:ok, %{difficulty: difficulty, confidence: 0.8, why: "palabras clave de prueba"}}
    end

    defp messages_to_text(messages), do: Enum.map_join(messages, " ", &to_string(&1.content))

    @impl true
    def name, do: :tags

    @impl true
    def enabled?(_opts), do: true
  end

  defmodule Torpe do
    @moduledoc "Un clasificador que no sabe. Es el caso `:unknown`."
    @behaviour Classifier

    @impl true
    def classify(_prompt, _opts), do: {:error, :unknown}

    @impl true
    def name, do: :torpe

    @impl true
    def enabled?(_opts), do: true
  end

  setup do
    :ok = Classifier.register(:tags, Tags)
    :ok = Classifier.register(:torpe, Torpe)

    on_exit(fn ->
      if :ets.whereis(:candil_router_classifiers) != :undefined,
        do: :ets.delete_all_objects(:candil_router_classifiers)
    end)

    :ok
  end

  defp prompt, do: [%{role: "user", content: "refactor esto"}]

  # ── el contrato ─────────────────────────────────────────────────────────────

  describe "el contrato" do
    test "devuelve dificultad, confianza y POR QUE" do
      assert {:ok, result} = Classifier.classify(prompt(), classifier: :tags)

      assert result.difficulty == :deep
      assert result.confidence == 0.8
      # El `why` no es un adorno: un clasificador que responde sin decir por
      # que es un clasificador que no se puede depurar cuando falla.
      assert result.why =~ "prueba"
    end

    test "la confianza es un numero entre 0 y 1, y no un string" do
      assert {:ok, %{confidence: c}} = Classifier.classify(prompt(), classifier: :tags)
      assert is_number(c)
      assert c >= 0.0 and c <= 1.0
    end
  end

  # ── lo que se gana ──────────────────────────────────────────────────────────

  describe "un clasificador de un tercero, SIN tocar Candil" do
    test "se registra y a partir de ahi decide" do
      # Este es EL test. Si pasa, la capa `:rule` deja de ser la unica.
      assert {:ok, %{difficulty: :deep}} = Classifier.classify(prompt(), classifier: :tags)
    end

    test "cada clasificador decide lo suyo" do
      # Dos prompts distintos, el mismo clasificador, y decisiones distintas.
      # Si todos los prompts dieran lo mismo, el clasificador no estaria
      # clasificando: estaria respondiendo con una constante.
      profundo = [%{role: "user", content: "refactor esto"}]
      facil = [%{role: "user", content: "hola"}]

      assert {:ok, %{difficulty: :deep}} = Classifier.classify(profundo, classifier: :tags)
      assert {:ok, %{difficulty: :fast}} = Classifier.classify(facil, classifier: :tags)
    end

    test "uno que no sabe devuelve `:unknown` y NO un error" do
      # `:unknown` es una TERCERA respuesta, distinta de "no hay decision" y de
      # "ha fallado". Con una respuesta menos, un clasificador timido obliga a
      # elegir a la fuerza, y ahi es donde se manda a un modelo caro.
      assert {:error, :unknown} = Classifier.classify(prompt(), classifier: :torpe)
    end
  end

  describe "elegir" do
    test "sin clasificador, la capa no existe y se dice" do
      # No hay clasificador por defecto, y eso es una DECISION. El clasificador
      # por defecto decide con que criterio se manda un prompt a un modelo caro,
      # y elegirlo por omision es elegirlo sin querer.
      assert Classifier.default_classifier() == nil
      assert Classifier.classifier_for(nil) == :error
    end

    test "uno que se registra pero esta apagado, no se usa" do
      defmodule Apagado do
        @behaviour Classifier
        def classify(_p, _o), do: {:ok, %{difficulty: :deep, confidence: 1.0, why: ""}}
        def name, do: :apagado
        def enabled?(opts), do: Keyword.get(opts, :enable, true)
      end

      :ok = Classifier.register(:apagado, Apagado)

      # Registrado pero apagado: la capa existe, y no se usa. Es lo que
      # `enable_llm_classifier = false` tiene que significar.
      assert Classifier.registered?(:apagado)
      assert Classifier.enabled?(:apagado, enable: false) == false
    end
  end
end
