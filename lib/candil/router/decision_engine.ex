defmodule Candil.Router.DecisionEngine do
  @moduledoc """
  Runs the four routing layers in cost order and returns the first decision
  that clears its threshold.

  Cheapest first is not an optimisation, it is the whole design. Layer 2 is a
  keyword match against a table in memory; layer 4 is a completion. A router
  that started with the classifier would spend a model call on every request
  to save a fraction of one.

  Each layer reports which one produced the decision, because a router that
  cannot say why it chose a model cannot be tuned, only tolerated.
  """

  alias Candil.{Error, Router, Store}
  alias Candil.Router.{Cache, Consumer, Decision, Fallback, Scorer}
  alias Candil.Telemetry

  # Que capas se han probed de verdad en ESTA decision. Una bandera de proceso,
  # como la del bucle en `Scorer`, y por el mismo motivo: el valor tiene que
  # sobrevivir a un `with` de seis ramas sin pasar por los parametros de todas.
  #
  # Se limpia en el `after` de `decide/3` porque una bandera que se queda puesta
  # marca como "corrrieron las cuatro capas" la siguiente decision del mismo
  # proceso, que en un servidor es la siguiente peticion de siempre.
  @layers_ran {__MODULE__, :layers_ran}

  @doc """
  Decides, or explains why it cannot.

  Returns a `t:Decision.t/0` or `:no_models_for_consumer`.
  """
  @spec decide([map()], [atom()], keyword()) ::
          {:ok, Decision.t()} | {:error, term()} | {:classifier_unavailable, Error.t()}
  def decide(_messages, [], _opts), do: {:error, :no_models_for_consumer}

  def decide(messages, candidates, opts) do
    assert_not_classifying!()
    settings = Router.settings()
    degraded = skip_embeddings(messages, candidates, settings)

    # La capa que `--force-strategy` (o `force_strategy:`) ha pedido. Se lleva
    # abajo para NO volver a correrla: si ya corrio y no ha pasado su umbral,
    # volver a correrla es pagar dos veces por la misma pregunta — y en la capa
    # :llm dos veces quiere decir **dos inferencias**.
    forced_layer = Keyword.get(opts, :force_strategy)

    # El reloj arranca ANTES de la primera capa: una decision que tarda 40 ms
    # porque el embedder tardó 40 ms tiene que medirse con el embedder dentro.
    Process.put(@layers_ran, [])
    started = System.monotonic_time()

    try do
      # El orden es el de §19.2 y no se toca: cache, pin, forzado, reglas,
      # embeddings y por ultima el clasificador LLM, que es el que cuesta una
      # inferencia. Un `pin` gana a todo lo demas, y se comprueba antes de que
      # corra ninguna otra cosa.
      result =
        with :miss <- forced_model(candidates, opts, degraded),
             :miss <- cached(messages, opts, settings),
             :miss <- pinned(consumer(opts), candidates, degraded),
             :miss <- forced(messages, candidates, opts, settings, degraded),
             :miss <- by_rules(messages, candidates, settings, degraded, forced_layer) do
          # `||` NO vale aqui: solo funciona con booleanos, y estas capas devuelven
          # `:miss` o una tupla. Un `||` sobre `:miss` revienta con BadBooleanError
          # en la PRIMERA peticion que llega a la capa de embeddings.
          case by_embeddings(messages, candidates, settings, degraded, forced_layer) do
            :miss -> by_llm(messages, candidates, settings, degraded, forced_layer)
            other -> other
          end
        end
        |> finish(messages, candidates, settings, degraded, consumer(opts))

      announce(result, consumer(opts), started)
      result
    after
      Process.delete(@layers_ran)
    end
  end

  # ── La metrica del tribunal ──────────────────────────────────────────────
  #
  # UN evento por decision, aqui y en ningun otro sitio. Este es el cuello de
  # botella por el que pasa **toda** decision —la que gana una regla, la que cae
  # en el `:default`, la que sale de la cache— y `announce/3` es el unico sitio
  # que lo dice.
  #
  # Emitirlo dentro de `decide_by/5` habria sido mas facil de escribir y habria
  # sido **contar capas**: una peticion que prueba reglas, embeddings y LLM
  # emite ahi hasta tres veces, y el tribunal de §10 mide peticiones, no capas.
  # Un numero cuatro veces mayor no es un numero grande: es otro numero.
  defp announce({:ok, %Decision{} = decision}, consumer, started) do
    layers = Process.get(@layers_ran, [])

    Telemetry.emit_router_decision(
      decision.strategy,
      %{
        model: decision.model_alias,
        consumer: consumer,
        score: decision.score,
        degraded: decision.degraded,
        confidence: decision.confidence,
        layers_ran: layers,
        # `:llm in layers` y NO `decision.strategy == :llm`. El clasificador
        # puede correr, pagar su inferencia y NO pasar el umbral: la decision
        # seria entonces `:default` con el LLM ya cobrado, y un contador que
        # mirara solo la estrategia diria que el LLM no se llamo nunca.
        llm_called: :llm in layers
      },
      System.monotonic_time() - started
    )
  end

  # Una peticion que no decidio —error, `:classifier_unavailable`, ningun
  # candidato— NO emite. El tribunal mide fraccion de **decisiones**, y contar
  # aqui los fracasos seria meter en el denominador peticiones que no llegaron
  # a decidir nada.
  defp announce(_result, _consumer, _started), do: :ok

  # Marcar aqui, y no en `by_rules/4` ni en `by_llm/5`, porque los tres caminos
  # que llevan a una capa pasan por aqui —incluido `forced/5`— y es el unico
  # punto donde se puede afirmar que la capa **llego a ejecutarse**. En
  # `by_embeddings/5` la capa se marca solo si hay embedder, que es cuando de
  # verdad se consulta; si no lo hay, no se probo.
  defp mark_layer(layer) do
    Process.put(@layers_ran, Process.get(@layers_ran, []) ++ [layer])
  end

  # Que una capa se salte es un hecho de la DECISIÓN, no un detalle interno: si
  # el embedder no estaba, el score que gana no viene de la similitud y el
  # consumidor tiene derecho a saberlo. Sin esto, la decision con 0.42 de una
  # regla se parece exactamente a la decision con 0.42 de una similitud.
  defp skip_embeddings(_messages, _candidates, _settings) do
    if embedder_available?(), do: [], else: [:embedding]
  end

  defp finish({:ok, decision}, _messages, _candidates, _settings, _degraded, _consumer),
    do: {:ok, decision}

  # La capa LLM encendida y sin modelo se propaga TAL CUAL. Sin esta clausula
  # el error caia en el `FunctionClauseError` de abajo, que es peor que el
  # fallo que queria comunicar: el llamante recibia un crash por una capa
  # apagada, en vez de un `{:classifier_unavailable, error}` con el motivo.
  defp finish(
         {:classifier_unavailable, error},
         _messages,
         _candidates,
         _settings,
         _degraded,
         _consumer
       ),
       do: {:classifier_unavailable, error}

  defp finish(
         {:model_not_eligible, error},
         _messages,
         _candidates,
         _settings,
         _degraded,
         _consumer
       ),
       do: {:error, error}

  # Una capa que se ha roto de verdad —un embedder con vectores de otra
  # dimensión, un clasificador que revienta— corta aqui, y se dice cual era. Un
  # router que se rompe cuando le falta algo es preferible a uno que responde
  # mal y no lo dice: si no, esa decision con un 0.0 de similitud es
  # indistinguible de una decision en la que la capa funciono y no se parecio
  # nada.
  defp finish({:error, reason}, _messages, _candidates, _settings, _degraded, _consumer),
    do: {:error, reason}

  defp finish(:miss, _messages, candidates, settings, degraded, consumer) do
    # Cuando nada puntua. Antes esto era `List.last(candidates)` y punto: el
    # ultimo de la lista, escrito como si fuera una politica. Medido, es la
    # decision que MAS veces se toma —74 de 84 peticiones reales—, asi que lo
    # que hay debajo del enrutado no es un resto, es la mayor parte.
    #
    # Ahora sale de `[router] fallback`, y el `reason` dice **que** se uso, para
    # que un `:default`|round_robin` no se lea igual que un `:default`|last`.
    strategy = Fallback.configured(settings)

    {:ok, model_alias} = Fallback.pick(strategy, candidates, consumer)

    {:ok,
     %Decision{
       model_alias: model_alias,
       strategy: :default,
       score: 0.5,
       reason: "no layer cleared its threshold; fell back to #{inspect(strategy)}",
       alternatives: [],
       degraded: degraded,
       confidence: confidence(degraded),
       timestamp: DateTime.utc_now()
     }}
  end

  defp consumer(opts), do: Keyword.get(opts, :consumer, :default)

  defp cached(messages, opts, settings) do
    cond do
      not settings.enable_cache ->
        :miss

      Keyword.get(opts, :skip_cache, false) ->
        :miss

      true ->
        case Cache.get(messages, consumer(opts)) do
          {:ok, decision} ->
            # La cache se marca como capa consultada, y el evento la dice.
            #
            # NO se reescribe `decision.strategy` a `:cache` — although el tipo
            # lo declara y `Cache.get/2` devuelve la decision guardada tal
            # cual— porque eso cambia lo que un `if decision.strategy == :rule`
            # ya escrito ve, y no es instrumentacion sino otra politica.
            # Lo que NO se puede es que el evento diga `:rule` cuando en esta
            # peticion no corrio ninguna regla: eso es mentir sobre la capa, y
            # es justo lo que el tribunal viene a medir.
            mark_layer(:cache)
            {:ok, decision}

          :miss ->
            :miss
        end
    end
  end

  # `--model` gana a TODO, pin incluido. Es por peticion y explicito, asi que
  # va por delante del pin, que es del consumidor y dura mas.
  #
  # Y DICE POR QUE, como todo lo demas: un forzado sin motivo es una decision
  # que hay que debugar apagando el forzado, que es peor que no forzar.
  defp forced_model(candidates, opts, degraded) do
    case Keyword.get(opts, :force_model) do
      nil ->
        :miss

      alias ->
        if alias in candidates do
          {:ok,
           %Decision{
             model_alias: alias,
             strategy: :forced,
             score: 1.0,
             reason: "forzado a mano con --model #{alias}; el resto de capas ni se miran",
             alternatives: List.delete(candidates, alias),
             degraded: degraded,
             confidence: confidence(degraded),
             timestamp: DateTime.utc_now()
           }}
        else
          {:model_not_eligible, Error.model_not_in_candidates(alias, candidates)}
        end
    end
  end

  # Un pin, y solo un pin. La version anterior miraba si `candidates` quedaba
  # en UN SOLO elemento, que no es lo mismo: un consumidor con
  # `model_default = "coder"` en el toml tiene un unico candidato SIN tener
  # ningun pin, y se anunciaba como "pinned" con el motivo inventado de que
  # ，有一个 pin que lo saca todo. Se vio en la maquina del usuario asi:
  #
  #     $ candil route ask "lo que sea"   ->  estrategia: pinned
  #     $ candil route pin                ->  pin de default: ninguno
  #
  # Mientes sobre COMO se decidio, que es justo lo que el decision dice que
  # existe para. Un `reason` que no se corresponde con la realidad hace falta
  # para depurar, y el `force_model` se apoya en el mismo campo.
  defp pinned(consumer, candidates, degraded) do
    case {Consumer.pinned(consumer), candidates} do
      {{:ok, pinned_alias}, _} ->
        {:ok,
         %Decision{
           model_alias: pinned_alias,
           strategy: :pinned,
           score: 1.0,
           reason: "pin de #{consumer} a #{pinned_alias}; gana a todas las capas",
           degraded: degraded,
           confidence: confidence(degraded),
           timestamp: DateTime.utc_now()
         }}

      {_, [only]} ->
        # Un solo candidato sin pin: no es un pin, es que no habia donde elegir.
        # Se marca como `default`, que es lo que es, para que la diferencia con
        # un pin de verdad se vea en el `reason`.
        {:ok,
         %Decision{
           model_alias: only,
           strategy: :default,
           score: 1.0,
           reason:
             "este consumidor solo tiene un candidato, #{only}; no hay pin ni decision que tomar",
           degraded: degraded,
           confidence: confidence(degraded),
           timestamp: DateTime.utc_now()
         }}

      _ ->
        :miss
    end
  end

  defp forced(messages, candidates, opts, settings, degraded) do
    case Keyword.get(opts, :force_strategy) do
      nil ->
        :miss

      :rule ->
        decide_by(messages, candidates, :rule, settings, degraded)

      :embedding ->
        decide_by(messages, candidates, :embedding, settings, degraded)

      :llm ->
        decide_by(messages, candidates, :llm, settings, degraded)

      other ->
        {:ok,
         %Decision{
           model_alias: List.last(candidates),
           strategy: :default,
           score: 0.0,
           reason: "force_strategy: #{inspect(other)} is not a layer; used the default",
           timestamp: DateTime.utc_now()
         }}
    end
  end

  # `forced_layer` se mira aqui por la **misma** razon que en
  # `by_embeddings/5`: `force_strategy` significa «corre ESTA capa», y si la
  # capa forzada ya corrio y no paso su umbral, volver a correr otra capa no es
  # «intentar otra vez», es **ignorar lo que se pidio**.
  #
  # Sin esto se median dos rastros que no son verdad: forzando `:rule` salia
  # `[:rule, :rule, :embedding]` —las reglas dos veces— y forzando `:embedding`
  # salia `[:embedding, :rule]`, con la capa de reglas entrando igual. Y
  # `[:candil, :router, :decision]` documenta que su `:layers_ran` son las capas
  # que **corrieron**, no las que alguien queria que corrieran.
  defp by_rules(messages, candidates, settings, degraded, forced_layer) do
    if forced_layer == :rule do
      :miss
    else
      decide_by(messages, candidates, :rule, settings, degraded)
    end
  end

  defp by_embeddings(messages, candidates, settings, degraded, forced_layer) do
    cond do
      # Ya ha corrido con `force_strategy` y no ha pasado su umbral.
      forced_layer == :embedding ->
        :miss

      # Never reached without a model that can embed. Asking for embeddings from
      # a chat-only setup should be a no-op, not an error: the layer is an
      # optimisation and there is a cheaper one above it. Pero NO es lo mismo que
      # un acierto, y la decision lo lleva marcado.
      not embedder_available?() ->
        :miss

      true ->
        decide_by(messages, candidates, :embedding, settings, degraded)
    end
  end

  # El clasificador LLM esta APAGADO por defecto, y apagado se significa
  # apagado: si `enable_llm_classifier` es false, la capa no corre y no se nota.
  #
  # Si esta ENCENDIDO y no puede funcionar, **reventamos**, y decimos que modelo
  # falta. Degradar en silencio seria peor: el router cairia a las capas de
  # arriba, enrutaria "razonablemente" y no habria forma de saber que la capa
  # que activaste lleva semanas sin hacer nada. Un router que se rompe cuando
  # le falta algo es preferible a uno que responde mal y no lo dice.
  #
  # Y si puede funcionar, la capa DECIDE: antes esto devolvia siempre `:miss`
  # porque no estaba escrita, y el motor se comia el resultado sin mirarlo.
  defp by_llm(messages, candidates, settings, degraded, forced_layer) do
    cond do
      # Encendida y forzada es lo mismo que corrida: no se paga dos veces.
      forced_layer == :llm ->
        :miss

      not settings.enable_llm_classifier ->
        :miss

      classifier_model() == nil ->
        {:classifier_unavailable, no_classifier_model(candidates)}

      true ->
        decide_by(messages, candidates, :llm, settings, degraded)
    end
  end

  # `:unknown` y «no hay clasificador» NO llegan aqui como errores: la capa los
  # convierte en `:miss` antes. Lo que si llega es un fallo de verdad, y llega
  # como `{:error, motivo}` desde `decide_by/5`.

  # Cualquier modelo de chat sirve: clasificar es una peticion mas corta, y
  # obligar a un modelo "de clasificacion" seria inventar un concepto que el
  # toml no tiene.
  defp classifier_model do
    Store.list_models()
    |> Enum.find(fn model -> :chat in model.usage or :completion in model.usage end)
    |> case do
      nil -> nil
      model -> model.alias
    end
  end

  defp no_classifier_model(candidates) do
    Error.no_classifier_model(
      List.first(candidates),
      "enable_llm_classifier: true necesita un modelo para CLASIFICAR. Declara uno " <>
        "con usage = [\"chat\"] y arrancalo, o pon enable_llm_classifier: false."
    )
  end

  defp decide_by(messages, candidates, layer, settings, degraded) do
    # La capa se ha consultado DE VERDAD: a partir de aqui se llama a `Scorer`.
    # El clasificador LLM vive dentro de ahi, asi que esta linea es la que
    # hace que `:llm_called` signifique algo y no sea una copia de `:strategy`.
    mark_layer(layer)

    case Scorer.score(messages, candidates, layer, settings) do
      :miss ->
        :miss

      {:error, reason} ->
        {:error, reason}

      # El `reason` lo pone la CAPA, y no el motor, porque el veredicto del
      # clasificador —su dificultad, su confianza y su «por qué»— se muere
      # dentro de ella. Un motor que se lo compusiera estaria inventandolo.
      {:ok, [{model_alias, score} | rest], reason} ->
        if score >= threshold_for(layer, settings) do
          {:ok,
           %Decision{
             model_alias: model_alias,
             strategy: layer,
             score: score,
             reason: reason,
             alternatives: rest,
             degraded: degraded,
             confidence: confidence(degraded),
             timestamp: DateTime.utc_now()
           }}
        else
          :miss
        end
    end
  end

  # ── el bucle ─────────────────────────────────────────────────────────────
  #
  # `classifier_model/0` coge CUALQUIER modelo con `usage: [:chat]` y la capa
  # lo llama. Un clasificador implementado por el usuario que llame al router
  # para elegir modelo se llama a si mismo para siempre, y el sintoma de eso es
  # un proceso muerto por stack, que no dice nada de routers.
  #
  # Por eso la comprobacion esta AQUI, en la puerta, y no junto a la llamada al
  # clasificador: un clasificador puede llamar al router por mas de un camino
  # —`Router.route/2`, este `decide/3`, el que sea— y todos son el mismo bucle.
  #
  # Y por eso REVENTA en vez de degradar: un clasificador mal escrito es un
  # error de quien lo escribio, y se le dice con un mensaje que dice lo que
  # hacer. La regla, en una linea: **un clasificador llama al modelo
  # directamente; el router es lo que llama al clasificador.**
  defp assert_not_classifying! do
    case Scorer.current_classifier() do
      nil ->
        :ok

      module ->
        raise """
        bucle de enrutado: #{inspect(module)} ha pedido un modelo al router.

        El router llama al clasificador; si el clasificador vuelve a llamar al \
        router para elegir modelo, se llama a si mismo para siempre.

        La regla es: un clasificador llama al MODELO directamente —el \
        `Candil.Store`, el engine, el provider que toque—, saltandose el router. \
        El router es lo que llama al clasificador, y solo a el le corresponde \
        elegir.
        """
    end
  end

  # A keyword ratio and a cosine similarity are not the same kind of number.
  #
  # The `code` rule has eight words, and a real code prompt hits two or three
  # of them — "refactoriza este módulo de Elixir y arregla el bug" scores
  # 3/8 = 0.375. Against a 0.70 threshold borrowed from the semantic layers,
  # the rule layer could never fire, and every prompt would silently fall
  # through to the default.
  #
  # So each layer gets its own threshold, and the rule one is set where a
  # plausible prompt actually lands. Two words out of eight is a clear signal.
  @rule_threshold 0.20

  defp threshold_for(:rule, settings), do: Map.get(settings, :rule_threshold, @rule_threshold)
  defp threshold_for(:embedding, settings), do: settings.embedding_threshold
  defp threshold_for(_layer, settings), do: settings.confidence_threshold

  # Confianza degradada, scores SIN renormalizar. Renormalizar haria que un
  # modelo con 0.2 pareciera competir con uno de 0.9, que es mentir sobre lo
  # poco que se sabe.
  defp confidence([]), do: :full
  defp confidence(_degraded), do: :degraded

  defp embedder_available? do
    Store.list_models()
    |> Enum.any?(&(:embeddings in &1.usage))
  end
end
