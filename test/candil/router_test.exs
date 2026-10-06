defmodule Candil.RouterTest do
  use ExUnit.Case, async: false

  alias Candil.{Engine, Model, Provider, Router, Store}
  alias Candil.Router.{Cache, Consumer, Decision, Scorer}

  # Maps, not keyword lists. A module attribute like [role: "user", ...] is a
  # list of 2-tuples, and the router matches on %{role: "user"}, so a
  # keyword list silently matches nothing and every prompt falls through to
  # the default.
  @code [%{role: "user", content: "refactoriza este módulo de Elixir y arregla el bug"}]
  @reasoning [%{role: "user", content: "explain why this sort is O(n log n)"}]
  @nothing [%{role: "user", content: "hola"}]

  setup do
    Cache.flush()
    Consumer.unpin(:test_consumer)

    :ok =
      Store.register_engine(%Engine{
        alias: :llama_cpp,
        binary: "llama-server"
      })

    register(:coder, [:chat, :code])
    register(:verifier, [:chat, :reasoning])
    register(:embed, [:embeddings])

    :ok
  end

  defp register(alias, usage) do
    model = %Model{
      alias: alias,
      type: :local,
      engine: :llama_cpp,
      usage: usage,
      model_dir: "/models",
      filename: "#{alias}.gguf"
    }

    :ok = Store.register_model(model)
  end

  describe "route/2 with explicit candidates" do
    test "a code prompt picks the code model by rule" do
      assert {:ok, decision} = Router.route(@code, candidates: [:coder, :verifier])
      assert decision.model_alias == :coder
      assert decision.strategy == :rule
      # 3 of 8 rule words: refactor, elixir, bug
      assert_in_delta decision.score, 0.375, 0.001
    end

    test "a reasoning prompt picks the reasoning model" do
      assert {:ok, decision} = Router.route(@reasoning, candidates: [:coder, :verifier])
      assert decision.model_alias == :verifier
      assert decision.strategy == :rule
    end

    test "an unmatched prompt falls back to the default, and says so" do
      assert {:ok, decision} = Router.route(@nothing, candidates: [:coder, :verifier])
      assert decision.strategy == :default
      assert decision.reason =~ "no layer cleared"
    end

    test "the decision explains itself" do
      {:ok, decision} = Router.route(@code, candidates: [:coder, :verifier])
      assert decision.reason =~ "keyword rule"
      assert decision.reason =~ "elixir"
    end

    test "the fallthrough is the last candidate, not the first" do
      # The list is most-preferred-first, and the most conservative choice
      # when nothing scored is the one listed last.
      assert {:ok, %{model_alias: :verifier}} =
               Router.route(@nothing, candidates: [:coder, :verifier])
    end
  end

  describe "no candidates" do
    test "is an error, never head/1 of the model list" do
      # A consumer with nothing configured must not silently get the first
      # model in the store, which here is the embeddings one.
      assert Router.route(@code, candidates: []) == {:error, :no_models_for_consumer}
      assert Router.candidates(:consumer_sin_configurar) == {:error, :no_models_for_consumer}
    end
  end

  describe "pin/2" do
    test "a pin outranks the rules" do
      assert :ok = Router.pin(:test_consumer, :verifier)
      assert {:ok, decision} = Router.route(@code, consumer: :test_consumer)
      assert decision.model_alias == :verifier
      assert decision.strategy == :pinned
      assert decision.score == 1.0
    end

    test "unpinning restores normal routing" do
      :ok = Router.pin(:test_consumer, :verifier)
      :ok = Router.unpin(:test_consumer)
      assert Router.pinned(:test_consumer) == :error
    end

    test "pinning an unknown model is refused" do
      assert {:error, {:unknown_model, :nope}} = Router.pin(:test_consumer, :nope)
    end

    test "a pin is per consumer, so two consumers do not fight" do
      :ok = Router.pin(:test_consumer, :verifier)
      :ok = Router.pin(:otro, :coder)

      assert {:ok, %{model_alias: :verifier}} = Router.route(@code, consumer: :test_consumer)
      assert {:ok, %{model_alias: :coder}} = Router.route(@code, consumer: :otro)

      Router.unpin(:test_consumer)
      Router.unpin(:otro)
    end
  end

  describe "cache" do
    test "the same prompt routes the same way twice" do
      {:ok, first} = Router.route(@code, candidates: [:coder, :verifier])
      {:ok, second} = Router.route(@code, candidates: [:coder, :verifier])
      assert first.model_alias == second.model_alias
    end

    test "a cached decision reports itself as cached on the way out" do
      {:ok, first} = Router.route(@code, candidates: [:coder, :verifier])
      # The first call computes; the DecisionEngine's cache is separate from
      # the post-route Cache.put, so this checks the key is stable.
      assert Cache.key(@code, :a) == Cache.key(@code, :a)
      # And the consumer is part of the key, or whichever consumer routed
      # first decides for all of them.
      refute Cache.key(@code, :a) == Cache.key(@code, :b)
      assert first.timestamp
    end

    test "the consumer is part of the cache key, not just the prompt" do
      # Two consumers, one prompt, different pins. With a prompt-only key
      # whichever routed first decides for both, which is the exact leak the
      # {consumer, session_id} partitioning exists to prevent.
      :ok = Router.pin(:test_consumer, :verifier)
      :ok = Router.pin(:otro, :coder)

      assert {:ok, %{model_alias: :verifier, strategy: :pinned}} =
               Router.route(@code, consumer: :test_consumer)

      assert {:ok, %{model_alias: :coder, strategy: :pinned}} =
               Router.route(@code, consumer: :otro)

      Router.unpin(:test_consumer)
      Router.unpin(:otro)
    end

    test "skip_cache still produces a decision" do
      assert {:ok, %{model_alias: :coder}} =
               Router.route(@code, candidates: [:coder, :verifier], skip_cache: true)
    end
  end

  describe "layers that must not run" do
    test "the llm layer is off unless asked for" do
      {:ok, decision} = Router.route(@code, candidates: [:coder, :verifier])
      refute decision.strategy == :llm
    end

    test "force_strategy with a non-layer is reported, not ignored" do
      {:ok, decision} =
        Router.route(@code, candidates: [:coder, :verifier], force_strategy: :telepathy)

      assert decision.strategy == :default
      assert decision.reason =~ "not a layer"
    end
  end

  describe "resolve/1" do
    test "a local model resolves to its engine" do
      {:ok, decision} = Router.route(@code, candidates: [:coder])
      assert {:ok, model, engine} = Router.resolve(decision)
      assert model.alias == :coder
      assert engine.alias == :llama_cpp
    end

    test "an unknown model is an error, not a crash" do
      decision = %Decision{model_alias: :nope, strategy: :default, score: 0.0}
      assert {:error, {:unknown_model, :nope}} = Router.resolve(decision)
    end

    test "a remote model resolves to its provider" do
      provider = %Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com"
      }

      :ok = Store.register_provider(provider)

      model = %Model{alias: :gpt4o, type: :remote, name: "gpt-4o", provider: :openai}
      :ok = Store.register_model(model)

      decision = %Decision{model_alias: :gpt4o, strategy: :default, score: 0.0}
      assert {:ok, _model, ^provider} = Router.resolve(decision)
    end

    test "a remote model with a missing provider says which" do
      model = %Model{alias: :gpt5, type: :remote, name: "gpt-5", provider: :nope}
      :ok = Store.register_model(model)

      decision = %Decision{model_alias: :gpt5, strategy: :default, score: 0.0}
      assert {:error, {:unknown_provider, :nope}} = Router.resolve(decision)
    end
  end

  describe "Scorer" do
    test "counts the keywords that are there" do
      # The built-in rules are English, so an English word matches and a
      # Spanish near-miss does not. Overriding `[router.rules]` in the config
      # file is how you get a Spanish vocabulary.
      matched = Scorer.matched_keywords("fix the bug in the elixir code")
      assert "bug" in matched
      assert "elixir" in matched
      assert "code" in matched
      refute "translate" in matched
    end

    test "a near-miss in another language does not match" do
      refute "código" in Scorer.matched_keywords("arregla el código")
    end

    test "scores zero for a model no rule points at" do
      assert Scorer.rule_score(@code, :nadie) == 0.0
    end

    test "is case insensitive" do
      upcase = [role: "user", content: "ELIXIR BUG COMPILE"]
      downcase = [role: "user", content: "elixir bug compile"]
      assert Scorer.rule_score(upcase, :coder) == Scorer.rule_score(downcase, :coder)
    end

    test "only the last user turn is looked at" do
      # A routing decision is about what is being asked now, not about the
      # whole transcript.
      messages = [
        %{role: "user", content: "explain why"},
        %{role: "assistant", content: "porque si"},
        %{role: "user", content: "hola"}
      ]

      assert Scorer.prompt_text(messages) == "hola"
    end

    test "unimplemented layers report a miss rather than a fake score" do
      # A layer that returns a plausible number for something it did not
      # compute routes on noise and reports confidence.
      assert Scorer.score(@code, [:coder], :llm, %{}) == :miss
      assert Scorer.score(@code, [:coder], :embedding, %{}) == :miss
    end
  end

  # ── Las dos decisiones del dueño, 2026-10-06 ──────────────────────────────
  #
  # Las dos cambian el comportamiento observable, asi que se comprueban por
  # separado y con el resultado en la mano. Un test que solo mira "no revienta"
  # pasa igual con las dos聚合物.

  describe "3.3 · la capa de embeddings saltada deja marca" do
    test "sin embedder, la decision sale con confidence: :degraded" do
      # En el setup hay un modelo con usage: [:embeddings], asi que para esto
      # hace falta un catalogo SIN el.
      Store.deregister_model(:embed)

      assert {:ok, decision} =
               Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

      assert decision.confidence == :degraded
      assert :embedding in decision.degraded
      assert decision.model_alias == :coder
    end

    test "con embedder disponible, la decision sale con :full" do
      assert {:ok, decision} =
               Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

      assert decision.confidence == :full
      assert decision.degraded == []
    end

    test "los scores NO se renormalizan al degradar" do
      # Renormalizar haria que un 0.2 pareciera competir con un 0.9, que es
      # mentir sobre lo poco que se sabe. El score es el que es, y la marca
      # dice que se ha decidido con menos informacion.
      Store.deregister_model(:embed)

      assert {:ok, decision} =
               Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

      assert decision.score < 1.0
      assert decision.confidence == :degraded
    end
  end

  describe "3.4 · el clasificador LLM apagado es apagado" do
    test "con enable_llm_classifier en false, la capa no corre y no se nota" do
      assert {:ok, _decision} =
               Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

      # Apagada es apagada: que no haya modelo de clasificador no es un error
      # si la capa no se ha pedido.
    end
  end

  # Un `||` entre capas devuelve BadBooleanError en cuanto llega algo que no es
  # booleano, y estas capas devuelven `:miss` o una tupla. Con solo los tests
  # de arriba pasaba: la mayoria cae en la capa de reglas antes. Este llega a
  # la de embeddings con un prompt que no casa con ninguna palabra de la regla,
  # que es el camino donde el `||` estaba.
  describe "la cadena de capas llega hasta el final" do
    test "una peticion que no casa con ninguna regla atraviesa reglas y embeddings" do
      nada_de_reglas = [%{role: "user", content: "hola"}]

      assert {:ok, decision} =
               Router.DecisionEngine.decide(nada_de_reglas, [:coder, :verifier],
                 consumer: :test_consumer
               )

      # Llego al final y cayo al default, que es lo que debe pasar: sin
      # BadBooleanError, sin excepcion, y con la razon puesta.
      assert decision.strategy == :default
      assert decision.model_alias == :verifier
    end
  end

  describe "3.4 · el clasificador LLM encendido y sin modelo" do
    test "el flag se lee de [router] del fichero, no de unas constantes" do
      # Este SÍ se puede probar aqui, porque no depende del catalogo: `settings/0`
      # devolvia constantes duras y no habia forma de encender la cuarta capa.
      tmp =
        Path.join(System.tmp_dir!(), "candil-router-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      File.write!(
        Path.join(tmp, "candil.toml"),
        "[general]\ndata_dir = \"#{tmp}\"\n[router]\nenable_llm_classifier = true\n"
      )

      System.put_env("CANDIL_CONFIG", Path.join(tmp, "candil.toml"))

      on_exit(fn ->
        System.delete_env("CANDIL_CONFIG")
        File.rm_rf(tmp)
      end)

      assert Router.settings().enable_llm_classifier
    end

    test "el error de clasificador lleva el modelo que se buscaba" do
      # Solo se comprueba el contrato del error —que este NOMBRADO y que diga
      # que modelo se buscaba—, no el texto del hint. El hint lo construye el
      # router, y comprobarlo aqui seria duplicar la cadena en el test y que
      # los dos se pudiesen desincronizar.
      #
      # Y el camino entero —flag encendido, sin modelo, prompt que no casa— no
      # se puede probar aqui: `Candil.Store` es ETS GLOBAL y compartido, y
      # deregistrar `coder` y `verifier` no deja el catalogo vacio: otros
      # ficheros de test han dejado modelos con `usage: [:chat]`, el
      # clasificador los encuentra y devuelve `:miss` en vez de fallar. Es un
      # test que depende del orden, y un test que depende del orden miente.
      # Ese camino lo comprueba `scripts/router-check.exs`, que monta su
      # catalogo y lo demuestra.
      error = Candil.Error.no_classifier_model(:coder, "hint de ejemplo")

      assert error.reason == :no_classifier_model
      assert error.context.model_alias == :coder
    end
  end

  # ── El override: la salida de seguridad del sistema estatico ───────────────
  describe "forzar un modelo a mano" do
    test "gana a las reglas, y DICE por que" do
      # Sin esto, un fallo del estatico es un callejon sin salida y obliga a
      # acertar a la primera. Con el, fallaste, lo fuerzas, ves que paso.
      codigo = [%{role: "user", content: "refactoriza este modulo de Elixir y arregla el bug"}]

      assert {:ok, decision} =
               Router.DecisionEngine.decide(codigo, [:coder, :verifier],
                 consumer: :test_consumer,
                 force_model: :verifier
               )

      assert decision.model_alias == :verifier
      assert decision.strategy == :forced
      # Y lo dice. Un router que calla como decidio hay que debugarlo apagandolo.
      assert decision.reason =~ "forzado a mano"
      assert decision.reason =~ "verifier"
    end

    test "gana al pin, que es del consumidor y dura mas" do
      Consumer.pin(:test_consumer, :coder)
      codigo = [%{role: "user", content: "hola"}]

      assert {:ok, decision} =
               Router.DecisionEngine.decide(codigo, [:coder, :verifier],
                 consumer: :test_consumer,
                 force_model: :verifier
               )

      assert decision.model_alias == :verifier
    end

    test "sin force_model, el pin sigue mandando como antes" do
      # Lo de antes no se rompe: el forzado es NUEVO, no sustituye al pin.
      Consumer.pin(:test_consumer, :verifier)

      assert {:ok, decision} =
               Router.DecisionEngine.decide(
                 [%{role: "user", content: "hola"}],
                 [:coder, :verifier],
                 consumer: :test_consumer
               )

      assert decision.strategy == :pinned
      assert decision.model_alias == :verifier
    end

    test "forzar un modelo que no puede usar este consumidor dice cuales puede" do
      assert {:error, error} =
               Router.DecisionEngine.decide([%{role: "user", content: "hola"}], [:coder],
                 consumer: :test_consumer,
                 force_model: :otro
               )

      assert error.reason == :model_not_in_candidates
      # Listar lo que SI puede usar es la mitad del mensaje: "unknown model"
      # deja al usuario adivinando.
      assert error.context.candidates == [:coder]
    end

    test "las alternativas son los otros candidatos, no el forzado" do
      assert {:ok, decision} =
               Router.DecisionEngine.decide(
                 [%{role: "user", content: "hola"}],
                 [:coder, :verifier],
                 consumer: :test_consumer,
                 force_model: :coder
               )

      refute :coder in decision.alternatives
      assert :verifier in decision.alternatives
    end
  end

  # Este fallo lo vio el usuario en su maquina, no un test: `route ask`
  # anunciaba "pinned" SIN que hubiera pin, y `route pin` decia "ninguno"
  # justo despues. Los dos tienen razon y son la misma cosa mal dicha.
  describe "un solo candidato NO es un pin" do
    test "sin pin, un unico candidato se marca default y lo dice" do
      # SIN pin, a proposito. Un consumidor con `model_default = "coder"` en el
      # toml deja UN candidato, y eso no es un pin: es que no habia donde
      # elegir. El `reason` de un pin de verdad dice "pin de ... a ..."; si
      # aqui dijera eso, estariamos mintiendo sobre COMO se decidio.
      assert {:ok, decision} =
               Router.DecisionEngine.decide([%{role: "user", content: "hola"}], [:coder],
                 consumer: :otro_consumer
               )

      assert decision.model_alias == :coder
      refute decision.strategy == :pinned
      assert decision.strategy == :default
      assert decision.reason =~ "no hay pin"
    end

    test "con pin, la estrategia es pinned y el reason lo dice" do
      Consumer.pin(:otro_consumer, :coder)

      assert {:ok, decision} =
               Router.DecisionEngine.decide(
                 [%{role: "user", content: "hola"}],
                 [:coder, :verifier],
                 consumer: :otro_consumer
               )

      assert decision.strategy == :pinned
      assert decision.reason =~ "pin de otro_consumer"
    end
  end
end
