defmodule Candil.Router.Scorer do
  @moduledoc """
  Scores each candidate model against a message list, per routing layer.

  Rule scoring is a keyword ratio and nothing more clever: how many of the
  rule's words appear, over how many words the rule has. It is deliberately
  crude. A keyword router that pretends to understand the prompt is worse than
  one that admits it is counting words, because you can debug the first.

  The embedding and LLM layers are implemented, and both do the same thing and
  the opposite of each other: they **filter**.

  ## Qué hace cada una

  `:llm` pregunta a un `Candil.Router.Classifier` **qué tan difícil** es el
  prompt, y usa el veredicto para descartar por `usage`:

  | Veredicto | Se quedan |
  |---|---|
  | `:deep` | solo los modelos con `:reasoning` |
  | `:normal` | todos |
  | `:fast` | los que **no** son `:reasoning` |

  Si el filtro deja **cero**, la capa devuelve `:miss`. No se cae de vuelta a
  «todos»: un `:deep` sin ningún modelo de razonamiento tiene que poder decirse,
  porque mandarlo igualmente con la misma confianza es fingir que se ha filtrado
  algo.

  `:embedding` compara el prompt con la `description` de cada modelo
  (`Candil.Model`) por similitud del coseno. Sin descripciones no hay nada que
  comparar, y la capa devuelve `:miss` en vez de comparar con el alias.

  ## Lo que NO hacen, y por qué no

  **No ordenan.** La afinidad es la fase 4, y sus pesos no están decididos. Aquí
  las capas **filtran**; dentro de lo que pasa el filtro manda el orden del
  consumidor, y eso no es una opinión sobre la calidad de los modelos: es su
  orden de preferencia.

  **No normalizan la confianza.** La del clasificador sale tal cual, con su
  escala, porque el sitio donde se arregla es la afinidad.

  **No tienen implementación por defecto.** Ni clasificador ni embedder: los dos
  deciden por omisión cuánto se gasta o en qué se miden las distancias, y
  tomarlos sin que nadie los pida es tomarlos sin querer.

  **No devuelven un número que no han calculado.** Un `:miss` es la respuesta
  honesta; un 0.0 puesto por no saber comparar es indistinguible de «el prompt
  no se parece a nada», que es exactamente el bug que hace que un router
  parezca funcionar.

  ## El bucle, y por qué está en la puerta

  `DecisionEngine` coge **cualquier** modelo con `usage: [:chat]` para clasificar,
  y esta capa lo llama. Un clasificador implementado por el usuario que llame al
  router para elegir modelo **se llama a sí mismo para siempre**.

  Por eso hay una bandera (`classifying?/0`) que se levanta mientras dura la
  llamada al clasificador, y `Candil.Router.DecisionEngine.decide/3` la
  comprueba en la puerta. La regla es: **un clasificador llama al modelo
  directamente, saltándose el router. El router es lo que llama al
  clasificador.**
  """

  alias Candil.Embeddings.Adapter
  alias Candil.Router.Classifier
  alias Candil.Router.Scorer.VectorCache
  alias Candil.Store

  @type layer :: :rule | :embedding | :llm
  @type ranking :: [{atom(), float()}]

  @typedoc """
  Lo que devuelve una capa, con **tres** salidas y no dos.

  `{:ok, ranking, reason}` lleva el `reason` porque el veredicto del
  clasificador —su dificultad, su confianza y su «por qué»— se muere dentro de
  la capa, y la decisión lo necesita para poder explicar por qué se eligió un
  modelo. Una decisión con la estrategia puesta y sin motivo es una decision
  que hay que debugar apagando capas.

  `:miss` es una respuesta, no un fallo: la capa no sabe, y quien llama sigue
  bajando. `{:error, reason}` es lo de verdad roto —un clasificador que
  revienta, un embedder que devuelve vectores de otra dimensión— y no se
  disimula con un `:miss` ni con un 0.0.
  """
  @type result :: {:ok, ranking(), String.t()} | :miss | {:error, term()}

  @rules %{
    code: ["code", "function", "refactor", "bug", "compile", "elixir", "python", "test"],
    reasoning: ["reason", "explain", "why", "analyze", "prove", "compare"],
    fast: ["quick", "short", "summarize", "list", "translate"]
  }

  # English, deliberately. These are the fallbacks when `[router.rules]` is
  # absent from the config file; the real vocabulary belongs there, where it
  # can be written in whatever language the prompts are in. A near-miss across
  # languages does not match, and pretending otherwise would make the score a
  # lie.
  @default_rules %{
    code: :coder,
    reasoning: :verifier,
    fast: :gpt4o
  }

  @doc """
  The keyword rules, for `candil router test` to display.
  """
  @spec rules() :: map()
  def rules, do: @rules

  @doc """
  Scores candidates for a layer, best first.

  `settings` es el mapa de `Candil.Router.settings/0`. De el salen los dos
  nombres que eligen la implementacion: `:classifier` y `:embedder`. Sin ellos
  —o sin que haya algo registrado con ese nombre— la capa devuelve `:miss`.
  """
  @spec score([map()], [atom()], layer(), map()) :: result()
  def score(messages, candidates, :rule, settings) do
    rules = configured_rules(settings)

    ranked =
      candidates
      |> Enum.map(fn alias -> {alias, rule_score(messages, alias, rules)} end)
      |> Enum.reject(fn {_alias, score} -> score == 0.0 end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    if ranked == [], do: :miss, else: {:ok, ranked, explain(:rule, messages)}
  end

  def score(messages, candidates, :llm, settings) do
    name = Map.get(settings, :classifier, Classifier.default_classifier())

    case classify(messages, name, settings) do
      {:ok, module, verdict} ->
        keep_by_difficulty(candidates, module, verdict)

      # `:unknown` NO es un fallo, y esta distincion es el motivo de que el
      # clasificador tenga tres salidas. Un clasificador que no sabe puede
      # decirlo; quien no lo tiene esta obligado a elegir a la fuerza, y ahi
      # es donde se manda un prompt a un modelo caro sin querer.
      {:error, :unknown} ->
        :miss

      # No hay ningun clasificador con ese nombre, o esta apagado: la capa no
      # existe. Es lo mismo que no haberla escrito, y NO es un fallo del motor.
      {:error, {:no_classifier, _name}} ->
        :miss

      # Esto ya es un fallo de verdad —el clasificador revento— y se propaga.
      # Tratarlo como `:miss` seria dejar el router en silencio con una capa
      # que el usuario encendio y que no funciona.
      {:error, reason} ->
        {:error, {:classifier_failed, reason}}
    end
  end

  def score(messages, candidates, :embedding, settings) do
    # Lo barato primero, y en este orden a proposito: si no hay nada que
    # comparar, no se pregunta ni al registro ni al embedder. Un modelo sin
    # descripcion NO se compara con su alias ni con el nombre del fichero,
    # porque un 0 de similitud sacado de un texto que nadie escribio no es una
    # medida: es ruido con decimales.
    case described_candidates(candidates) do
      [] -> :miss
      described -> embed_and_compare(messages, described, settings)
    end
  end

  def score(_messages, _candidates, layer, _settings) do
    # Una capa que no existe todavia. No devuelve ceros: devolver ceros no
    # limpia ningun umbral, pero haria que `candil router stats` dijera que la
    # capa ha corrido.
    _ = layer
    :miss
  end

  @doc """
  The rule score of one model: matched keywords over rule size.
  """
  @spec rule_score([map()], atom()) :: float()
  def rule_score(messages, model_alias, rules \\ nil) do
    text = prompt_text(messages)
    lowered = String.downcase(text)

    (rules || default_rules_map())
    |> words_for(model_alias)
    |> case do
      [] ->
        0.0

      words ->
        # **Cobertura del prompt**, no del diccionario. Medido el 2026-10-14
        # con el catalogo real y doce preguntas en cuatro idiomas:
        #
        #    Words que casan / tamaño del DICCIONARIO  ->   1 de 12 pasa de 0.20
        #     words que casan / tamaño del PROMPT      ->  10 de 12 pasan de 0.20
        #
        # Y las dos formulas **eligen el mismo modelo** (12/12): la de antes no
        # decidia mal, **anulaba la decision**. Con un diccionario de 30
        # palabras hacían falta 6 para llegar al umbral, y con uno de 3 bastaba
        # una: ampliar el vocabulario —que es lo que hay que hacer para que
        # caso en cuatro idiomas — **empeoraba** el score.
        #
        # Ademas 0.20 deja de ser un numero sin significado: pasa a ser «el 20%
        # de las palabras de la pregunta ».
        cobertura(words, lowered)
    end
  end

  defp cobertura(words, lowered) do
    del_prompt = lowered |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    case del_prompt do
      [] -> 0.0
      _ -> Enum.count(words, &String.contains?(lowered, &1)) / length(del_prompt)
    end
  end

  # Las palabras de UN alias, del mapa que toque.
  defp words_for(map, model_alias) do
    case Map.get(map, model_alias) do
      words when is_list(words) -> Enum.filter(words, &is_binary/1)
      _other -> []
    end
  end

  # El vocabulario que sale de `[router.rules.<alias>] words = [...]`.
  #
  # Se **indexa por alias y no por categoria** a proposito: el `@rules` viejo
  # tenia dos niveles —categoria, y categoria -> alias en `@default_rules`— y
  # eso obligaba a configurar **dos** cosas para anadir un modelo. Con una sola,
  # escribir el alias es anadirlo. Y las dos cosas que se configuraban una era
  # codigo.
  #
  # Un `@rules` que se queda aqui es lo que se usa cuando no hay `[router.rules]`.
  # Sigue siendo el comportamiento de antes, y sigue siendo el que no se puede
  # tocar; la diferencia es que ahora hay una manera de tocarlo.
  defp configured_rules(%{rules: rules}) when is_map(rules) do
    # Un alias del toml que no exista como atomo **se descarta**, no se crea.
    # El Store ya hizo sus atomos al leer el toml de modelos; si uno de aqui no
    # esta, es que no hay ningun modelo con ese nombre y la regla no tiene a
    # quien aplicarse. Crear el atomo seria inventar un destino, y ademas
    # initions las llama con `existing/1`, no con `to_atom/1`: un `to_atom`
    # aqui es un `String.to_atom` por peticion disfrazado.
    rules
    |> Enum.flat_map(fn {alias, value} ->
      case existing(alias) do
        {:ok, atom} -> [{atom, words_of(value)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp configured_rules(_settings), do: nil

  # Del toml llegan DOS formas y las dos valen:
  #
  #     [router.rules.coder]              -> %{"coder" => %{"words" => [...]}}
  #     rules = { coder = [...] }         -> %{coder: [...]}
  #
  # Aceptar las dos no es laxitud: la primera es la que dice la plantilla, y la
  # segunda es la que sale de un `rules = {...}` a pelo. Exigir una sola obliga
  # a quien escribe el fichero a recordar cual de las dos es.
  defp words_of(%{"words" => words}) when is_list(words), do: words
  defp words_of(words) when is_list(words), do: words
  defp words_of(_other), do: []

  # El toml trae strings; los alias son atomos de verdad, los que estan en el
  # Store. Un alias inventado aqui crearia un atomo por peticion.
  defp existing(name) when is_atom(name), do: {:ok, name}

  defp existing(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # `@rules` + `@default_rules` aplanados a `{alias => palabras}`, que es la
  # forma que entiende `words_for/2`.
  defp default_rules_map do
    @rules
    |> Enum.reduce(%{}, fn {category, words}, acc ->
      Map.update(acc, target_for(category), words, &(&1 ++ words))
    end)
  end

  @doc """
  A human-readable explanation of what a layer looked at.
  """
  @spec explain(layer(), [map()]) :: String.t()
  def explain(:rule, messages) do
    "keyword rule matched #{inspect(matched_keywords(prompt_text(messages)))}"
  end

  def explain(layer, _messages) do
    # Solo se llega aqui cuando la capa ha devuelto `:miss`. El `reason` de
    # una capa que SI ha opinado lo pone la propia capa, que es la unica que
    # sabe cual fue su veredicto.
    "#{layer} layer did not clear its threshold"
  end

  # ── la capa :llm ─────────────────────────────────────────────────────────

  # El bucle, en una bandera de proceso. `DecisionEngine.decide/3` la mira en
  # la puerta, y por eso va en la puerta y no aqui: un clasificador puede
  # llamar al router por mas de un camino, y todos son el mismo bucle.
  @classifying {__MODULE__, :classifying}

  @doc """
  Si este proceso está dentro de una llamada a un clasificador.

  ## Por que es publico

  Para que `Candil.Router.DecisionEngine` lo compruebe **antes** de enrutar, y
  para que un test pueda demostrar que la guardia se levanta al salir: una
  bandera que se queda puesta envenena el siguiente prompt del mismo proceso,
  que en un servidor es el siguiente prompt de siempre.
  """
  @spec classifying?() :: boolean()
  def classifying?, do: current_classifier() != nil

  @doc """
  El clasificador al que está llamando este proceso ahora mismo, o `nil`.

  @doc \"""
  El modulo va en la bandera y no un `true` a secas porque el bucle tiene que
  poder **nombrar** a quien lo introduce: un mensaje que dice «un clasificador»
  y otro que dice «`MiClasificador`» no cuestan lo mismo cuando el que lo lee
  es el que lo escribió.
  """
  @spec current_classifier() :: module() | nil
  def current_classifier, do: Process.get(@classifying)

  # Se resuelve el modulo ANTES de llamar, y no despues, por dos razones: el
  # `name/0` del clasificador va en el `reason` de la decision, y preguntar
  # «¿quien ha classifying?» despues es una carrera —alguien puede haberse
  # registrado en medio— y un `reason` que dice un nombre equivocado.
  defp classify(messages, name, settings) do
    case Classifier.classifier_for(name, classifier_opts(settings)) do
      :error ->
        {:error, {:no_classifier, name}}

      {:ok, module} ->
        # La bandera se levanta aqui y se baja en el `after`, pase lo que pase.
        # Un clasificador que revienta con `raise` no puede dejar el proceso
        # con la bandera puesta: en un servidor, ese proceso es el que va a
        # enrutar el siguiente prompt.
        previous = Process.put(@classifying, module)

        try do
          case module.classify(messages, classifier_opts(settings)) do
            {:ok, verdict} -> {:ok, module, verdict}
            other -> other
          end
        after
          Process.put(@classifying, previous)
        end
    end
  end

  # `Classifier.classify/2` espera una keyword list y el motor tiene un mapa.
  # Los dos son el mismo `settings`: lo que sale de `[router]` en el TOML.
  defp classifier_opts(settings), do: Map.to_list(settings)

  defp keep_by_difficulty(candidates, module, verdict) do
    with :ok <- known_difficulty(verdict.difficulty) do
      kept = Enum.filter(candidates, &allows?(capabilities_of(&1), verdict.difficulty))

      # Cero NO es «todos». Un `:deep` sin ningun modelo de razonamiento tiene
      # que poder decirse, porque mandarlo igualmente con la misma confianza es
      # fingir que se ha filtrado algo.
      if kept == [] do
        :miss
      else
        confidence = verdict.confidence

        {:ok, Enum.map(kept, &{&1, confidence}), reason_for(module, verdict, kept)}
      end
    end
  end

  # Una dificultad que no existe no es un `:normal` disfrazado: es un
  # clasificador que ha roto su contrato, y quien lo ha roto tiene que verlo en
  # vez de encontrar un prompt enviado a un modelo cualquiera con un 0.9 al lado.
  defp known_difficulty(:fast), do: :ok
  defp known_difficulty(:normal), do: :ok
  defp known_difficulty(:deep), do: :ok
  defp known_difficulty(other), do: {:error, {:unknown_difficulty, other}}

  # Esto lee **capacidades**, no `usage`. Antes leia `usage`, y era la misma
  # lista que decide que endpoints sirve un modelo: dos preguntas distintas en
  # el mismo sitio. `:reasoning` nunca fue un endpoint —se puede pedir una
  # peticion de chat a un modelo que razona— asi que lo que se consulta aqui es
  # `capabilities`.
  defp allows?(capacidades, :deep), do: :reasoning in capacidades
  defp allows?(capacidades, :fast), do: :reasoning not in capacidades
  defp allows?(_capacidades, :normal), do: true

  # Un alias que no esta en el catalogo no se puede decir que tenga
  # `:reasoning`, asi que no sobrevive a un `:deep` ni a un `:fast`. En un
  # `:normal` no hay filtro y se queda: el filtro de verdad lo hace el
  # `DecisionEngine`, que ya ha resuelto los candidatos.
  defp capabilities_of(alias) do
    case Store.get_model(alias) do
      {:ok, model} -> model.capabilities
      {:error, :not_found} -> []
    end
  end

  defp reason_for(module, verdict, kept) do
    "el clasificador #{module.name()} dijo #{verdict.difficulty} con confianza " <>
      "#{verdict.confidence}, SIN normalizar (#{verdict.why}); " <>
      "el filtro deja #{inspect(kept)} por `capabilities`"
  end

  # ── la capa :embedding ───────────────────────────────────────────────────

  defp described_candidates(candidates) do
    Enum.flat_map(candidates, fn alias ->
      case description_of(alias) do
        nil -> []
        text -> [{alias, text}]
      end
    end)
  end

  defp embed_and_compare(messages, described, settings) do
    name = Map.get(settings, :embedder, Adapter.default_embedder())

    case Adapter.adapter_for(name) do
      # No hay embedder por defecto, y eso es una decision: uno por defecto
      # decide, para todo el mundo y sin que nadie lo pidiera, EN QUE se
      # calculan las distancias entre vectores.
      :error ->
        :miss

      {:ok, module} ->
        # `supports?/1` es el embedder diciendo «esto no lo sé hacer». No es un
        # fallo del motor: es que este embedder no sirve para comparar texto.
        if module.supports?(:text) do
          compare(messages, described, module, name)
        else
          :miss
        end
    end
  end

  defp compare(messages, described, module, name) do
    prompt = prompt_text(messages)
    texts = [prompt | Enum.map(described, &elem(&1, 1))]

    with {:ok, [prompt_vector | vectors]} <- embed_all(module, name, texts),
         :ok <- check_dimensions(module, name, prompt_vector, vectors) do
      ranked =
        described
        |> Enum.zip(vectors)
        |> Enum.map(fn {{alias, _text}, vector} -> {alias, cosine(prompt_vector, vector)} end)
        |> Enum.sort_by(&elem(&1, 1), :desc)

      {:ok, ranked, embedding_reason(ranked)}
    end
  end

  # Sin `with` a proposito: en un `with`, la expresion de la izquierda se
  # EVALUA antes que el patron, asi que un `String.trim/1` con `nil` reventaria
  # antes de que el guard tuviera ocasion de mirarlo. Un `case` si dice lo que
  # quiere decir: sin descripcion, no hay nada que comparar.
  defp description_of(alias) do
    case Store.get_model(alias) do
      {:ok, model} -> trimmed_description(model)
      {:error, :not_found} -> nil
    end
  end

  defp trimmed_description(%{description: description}) when is_binary(description) do
    case String.trim(description) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed_description(_model), do: nil

  # Embeddear N descripciones en cada decision es carisimo, y el prompt se
  # repite: un router que paga una inferencia para decidir a quien se lo manda
  # esta pagando el doble. El cache es una decision de COSTE, no de exactitud
  # —el vector de un texto no cambia porque se le haya pedido dos veces— y va
  # POR TEXTO y POR EMBEDDER, que son las dos cosas que lo hacen distinto.
  defp embed_all(module, name, texts) do
    case Enum.reject(texts, &VectorCache.cached?(name, module, &1)) do
      [] ->
        {:ok, Enum.map(texts, &VectorCache.fetch(name, module, &1))}

      missing ->
        case module.embed(missing, adapter_opts(name)) do
          {:ok, vectors} when length(vectors) == length(missing) ->
            missing
            |> Enum.zip(vectors)
            |> Enum.each(fn {text, vector} -> VectorCache.put(name, module, text, vector) end)

            {:ok, Enum.map(texts, &VectorCache.fetch(name, module, &1))}

          {:ok, other} ->
            # Alinearlos por posicion seria comparar el prompt con la
            # descripcion de otro modelo, y en silencio.
            {:error, {:embeddings_count_mismatch, length(missing), length(other)}}

          {:error, reason} ->
            {:error, {:embeddings_failed, reason}}
        end
    end
  end

  # Un `0.0` aqui seria indistinguible de «el prompt no se parece a nada», y
  # por tanto indistinguible de «no se ha comparado nada». Es la misma mentira
  # que daba un stub, y por eso lleva los dos numeros en vez de un 0.
  defp check_dimensions(module, name, prompt_vector, vectors) do
    expected = module.dimension(adapter_opts(name))

    Enum.reduce_while([prompt_vector | vectors], :ok, fn vector, _acc ->
      case vector do
        list when is_list(list) ->
          case length(list) do
            ^expected ->
              {:cont, :ok}

            got ->
              {:halt, {:error, {:dimension_mismatch, expected: expected, got: got}}}
          end

        # Un embedder que devuelve `[1.0, 0.0, 0.0]` para UN texto parece un
        # vector y es una lista de tres numeros. Sin esta comprobacion, el
        # `length/1` de mas abajo coincide y la comparacion se hace con
        # numeros sueltos.
        other ->
          {:halt, {:error, {:not_a_vector, other}}}
      end
    end)
  end

  defp cosine(a, b) do
    with norm_a when norm_a > 0.0 <- norm(a),
         norm_b when norm_b > 0.0 <- norm(b) do
      dot(a, b) / (norm_a * norm_b)
    else
      # Un vector de norma cero no tiene direccion, y el coseno de algo sin
      # direccion no esta definido. Aqui 0.0 SI es la respuesta honesta —no se
      # parece a nada— y ademas evita un NaN colado en el `Enum.sort_by/3`. El
      # desajuste de dimensiones, que SI es un desajuste, es error y va en
      # `check_dimensions/4`.
      _ -> 0.0
    end
  end

  defp dot(a, b), do: Enum.zip_reduce([a, b], 0.0, fn [x, y], acc -> acc + x * y end)
  defp norm(vector), do: :math.sqrt(dot(vector, vector))

  defp embedding_reason(ranked) do
    {top_alias, top_score} = hd(ranked)

    "similitud del coseno contra la `description` de cada modelo; la mejor es " <>
      "#{top_alias} con #{Float.round(top_score, 3)}"
  end

  # La capa solo tiene una cosa que pasarle al embedder, y es su propio nombre.
  # Se manda igualmente, porque un embedder puede querer el nombre para elegir
  # modelo, y un `[]` no le dice nada.
  defp adapter_opts(name), do: [provider: name]

  @doc """
  Tira la cache de vectores de la capa `:embedding`.

  Existe para los tests —es ETS global— y para quien cambie de embedder con el
  mismo nombre y quiera que no le queden vectores del anterior.
  """
  @spec flush_vector_cache() :: :ok
  def flush_vector_cache, do: VectorCache.flush()

  @doc """
  Which keywords from any rule appear in the text.
  """
  @spec matched_keywords(String.t()) :: [String.t()]
  def matched_keywords(text) do
    lowered = String.downcase(text)

    @rules
    |> Enum.flat_map(fn {_category, words} -> words end)
    |> Enum.filter(&String.contains?(lowered, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The prompt text a router actually looks at: the last user turn.
  """
  @spec prompt_text([map()]) :: String.t()
  def prompt_text([]), do: ""

  def prompt_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} -> content
      _ -> nil
    end)
  end

  defp target_for(category), do: Map.get(@default_rules, category)
end

defmodule Candil.Router.Scorer.VectorCache do
  @moduledoc """
  Un vector por texto, por embedder. En ETS, y en un fichero de texto.

  ## Por que existe

  La capa `:embedding` compara el prompt con la `description` de cada modelo, y
  para eso hay que **embeddear**. Embeddear N descripciones en cada decision es
  carisimo, y encima el prompt se repite: la misma pregunta, la misma
  comparacion, la misma inferencia. Un router que paga una inferencia para
  decidir a quien se lo manda esta pagando el doble.

  Es una decision de **COSTE**, no de exactitud: el vector de un texto no cambia
  porque se le haya pedido dos veces. Lo que si cambia es el embedder, y por eso
  la clave lleva el nombre **y** el modulo: dos embedders no comparten vectores,
  ni aunque se llamen parecido.

  ## Por que se tira entera y no se hace un LRU

  Lo que se guarda son las descripciones de los modelos y los prompts que se
  repiten, unas pocas centenas de vectores. Un LRU aqui seria contabilidad para
  no growcer un numero que ya es pequeno, y el borrado entero cuesta una linea
  y no tiene un caso malo: lo unico que se pierde es un vector, que se vuelve a
  pedir.
  """

  @table :candil_router_vectors

  # Suficiente para el catalogo entero mas unas cuantascientas preguntas
  # repetidas. Pasado ese punto se tira, y el siguiente prompt lo vuelve a
  # pedir: el coste de equivocarse es una inferencia, no una respuesta mala.
  @max_entries 512

  @doc false
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  @doc "Si este texto ya tiene vector para este embedder."
  @spec cached?(atom(), module(), String.t()) :: boolean()
  def cached?(name, module, text) do
    ensure_table()
    :ets.member(@table, {name, module, text})
  end

  @doc "El vector de un texto. `:undefined` si no esta, que se distingue de `[]`."
  @spec fetch(atom(), module(), String.t()) :: [float()] | :undefined
  def fetch(name, module, text) do
    ensure_table()

    case :ets.lookup(@table, {name, module, text}) do
      [{_key, vector}] -> vector
      [] -> :undefined
    end
  end

  @doc "Guarda el vector de un texto."
  @spec put(atom(), module(), String.t(), [float()]) :: :ok
  def put(name, module, text, vector) do
    ensure_table()

    if :ets.info(@table, :size) > @max_entries do
      :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, {{name, module, text}, vector})
    :ok
  end

  @doc """
  Tira la cache entera.

  La usa la suite entre tests —es ETS global, como el Store, y un vector que
  metio un test aparece en el siguiente— y sirve para recargar tras cambiar de
  embedder con el mismo nombre.
  """
  @spec flush() :: :ok
  def flush do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end
