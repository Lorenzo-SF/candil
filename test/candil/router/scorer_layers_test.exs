defmodule Candil.Router.ScorerLayersTest do
  @moduledoc """
  Las dos capas que faltaban: `:llm` y `:embedding`.

  ## Que se prueba aqui y que NO

  Aqui se prueba **la capa**: que filtra, que se niega a dar un numero que no
  ha calculado, y que un `:deep` sin modelo de razonamiento se dice en vez de
  disimularse. La llamada externa —el clasificador, el embedder— va MOCK, que
  es el patron de los tests de Elasticsearch: primero el mock, y la llamada
  real en otro sitio.

  ## Lo que NO se puede probar aqui, y por que

  Que un LLM real clasifique bien, y que un embedder real de similitudes
  utiles. **Eso no es un test, es una medicion**, y se mide en la maquina del
  dueno con `scripts/router-layers-check.exs`. Aqui, un clasificador que
  devuelve siempre `:deep` pasaria todos los tests de este fichero, y eso
  tiene que quedar dicho: estos tests comprueban el MECANISMO, no la
  UTILIDAD. Confundir las dos cosas es como se acaba creyendo que el router
  enruta bien porque las capas devuelven numeros.
  """

  use Candil.StoreCase
  import Mox

  alias Candil.Embeddings.{Adapter, AdapterMock}
  alias Candil.Model
  # `alias Candil.Router.{..., Router}` daria `Candil.Router.Router`: en la
  # lista el nombre se ANADE al namespace, no lo nombra.
  alias Candil.Router, as: Router
  alias Candil.Router.{Classifier, ClassifierMock, DecisionEngine, Scorer}
  # Los clasificadores de prueba van los ultimos porque Credo ordena por el
  # nombre COMPLETO, y el de uno anidado es `Candil.Router.<Este>.Ciclico`.
  alias __MODULE__.{Apagado, Ciclico, CiclicoDirecto, Sano}

  @prompt [%{role: "user", content: "refactoriza este modulo de Elixir"}]
  @prompt_text "refactoriza este modulo de Elixir"

  # Tres vectores de 3 dimensiones, en un espacio donde las similitudes se
  # saben a mano:
  #   prompt = [1, 0, 0]
  #   codigo = [1, 0, 0]        -> 1.0
  #   razon  = [0, 1, 0]        -> 0.0
  #   mixto  = [0.9, 0.1, 0]    -> 0.9938
  @vectors %{
    @prompt_text => [1.0, 0.0, 0.0],
    "escribe codigo" => [1.0, 0.0, 0.0],
    "razona sobre codigo" => [0.0, 1.0, 0.0],
    "escribe prosa y explica" => [0.9, 0.1, 0.0]
  }

  setup :verify_on_exit!

  setup do
    # La cache de vectores es ETS global, como el Store. Sin vaciarla, el
    # vector que metio el test de antes aparece en el de ahora y el mock no
    # llega a llamarse: el test pasa probando el resultado de otro.
    Scorer.flush_vector_cache()
    clear_registries()
    :ok
  end

  # ── la capa :llm ─────────────────────────────────────────────────────────

  describe "la capa :llm filtra por dificultad" do
    setup do
      put_model(:coder, [:chat, :code], "escribe codigo")
      put_model(:verifier, [:chat, :reasoning], "razona sobre codigo")
      put_model(:gpt4o, [:chat], "responde de todo")
      :ok = Classifier.register(:mock, ClassifierMock)
      stub(ClassifierMock, :enabled?, fn _opts -> true end)
      stub(ClassifierMock, :name, fn -> :mock end)
      :ok
    end

    test "sin clasificador registrado la capa NO existe, y no es un error" do
      # No hay clasificador por defecto, y eso es una decision: el clasificador
      # por defecto decide con que criterio se manda un prompt a un modelo caro,
      # y elegirlo por omision es elegirlo sin querer.
      assert Classifier.default_classifier() == nil

      # `settings` sin `:classifier` y sin default -> nadie a quien preguntar.
      # Y como el mock esta registrado, un `:miss` aqui solo puede significar
      # que la capa NO lo ha llamado.
      assert Scorer.score(@prompt, [:coder, :verifier], :llm, %{}) == :miss
    end

    test "un clasificador que NO sabe devuelve :miss, no un error" do
      expect(ClassifierMock, :classify, fn _messages, _opts -> {:error, :unknown} end)

      # `:unknown` es una TERCERA respuesta, distinta de "no hay decision" y de
      # "ha fallado". Si aqui se devolviera un error, el router dejaria de
      # enrutar por un clasificador que no sabe, que es justo cuando mas falta
      # hace enrutar.
      assert Scorer.score(@prompt, [:coder, :verifier], :llm, %{classifier: :mock}) == :miss
    end

    test ":deep deja SOLO los modelos de razonamiento" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :deep, confidence: 0.9, why: "esto es dificil"}}
      end)

      assert {:ok, ranked, reason} =
               Scorer.score(@prompt, [:coder, :verifier, :gpt4o], :llm, %{classifier: :mock})

      # El unico de :reasoning. Que `coder` y `gpt4o` no aparezcan es la
      # asercion que importa: un :deep que se cumple con un modelo sin
      # razonamiento es un :deep que no se cumplio.
      assert Enum.map(ranked, &elem(&1, 0)) == [:verifier]
      assert reason =~ "deep"
    end

    test ":deep SIN ningun modelo de razonamiento es :miss, NO la lista entera" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :deep, confidence: 0.95, why: "muy dificil"}}
      end)

      # Los dos candidatos siguen ahi y ninguno tiene `:reasoning`. Caer de
      # vuelta a "todos" seria decir «esto es dificil, te lo mando al que sea»
      # con un 0.95 de confianza al lado.
      assert Scorer.score(@prompt, [:coder, :gpt4o], :llm, %{classifier: :mock}) == :miss
    end

    test ":fast deja los que NO son de razonamiento: no se paga lo caro para algo facil" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :fast, confidence: 0.7, why: "trivial"}}
      end)

      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:coder, :verifier, :gpt4o], :llm, %{classifier: :mock})

      assert Enum.map(ranked, &elem(&1, 0)) == [:coder, :gpt4o]
    end

    test ":normal deja todos, porque :normal no dice nada" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :normal, confidence: 0.6, why: "normal"}}
      end)

      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:coder, :verifier], :llm, %{classifier: :mock})

      assert Enum.map(ranked, &elem(&1, 0)) == [:coder, :verifier]
    end

    test "la confianza NO se normaliza: sale con la escala del clasificador" do
      # 3.0 no es una confianza, es la escala de ESE clasificador. El motor
      # compara contra su umbral; quien lo arregla es la afinidad (fase 4), y
      # aqui no se toca.
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :normal, confidence: 3.0, why: "escala propia"}}
      end)

      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:coder, :verifier], :llm, %{classifier: :mock})

      assert Enum.uniq(Enum.map(ranked, &elem(&1, 1))) == [3.0]
    end

    test "el filtro NO ordena: la lista sale en el orden de preferencia" do
      # Aqui no hay afinidad (fase 4). La capa FILTRA, y quien elige dentro de
      # lo que pasa el filtro es el orden del consumidor.
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :normal, confidence: 0.8, why: ""}}
      end)

      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:gpt4o, :coder, :verifier], :llm, %{classifier: :mock})

      assert Enum.map(ranked, &elem(&1, 0)) == [:gpt4o, :coder, :verifier]
    end

    test "el motivo del clasificador acaba en el `reason` de la decision" do
      # Sin esto, una decision de la capa :llm es un numero sin origen: el
      # clasificador sabe por que, y ese "por que" se perderia por el camino.
      stub(ClassifierMock, :name, fn -> :etiquetas end)

      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :deep, confidence: 0.9, why: "pide razonamiento"}}
      end)

      assert {:ok, [_only], reason} =
               Scorer.score(@prompt, [:verifier], :llm, %{classifier: :mock})

      assert reason =~ "pide razonamiento"
      assert reason =~ "etiquetas"
    end

    test "una dificultad que no existe es un error, no un :normal disfrazado" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :medium, confidence: 0.9, why: ""}}
      end)

      # Tratar `:medium` como si fuera `:normal` seria enviar un prompt a un
      # modelo cualquiera con un 0.9 de confianza. Un clasificador que rompe su
      # contrato tiene que notarlo quien lo rompio.
      assert {:error, {:unknown_difficulty, :medium}} =
               Scorer.score(@prompt, [:coder, :verifier], :llm, %{classifier: :mock})
    end

    test "un clasificador que falla de verdad NO se confunde con :unknown" do
      expect(ClassifierMock, :classify, fn _m, _o -> {:error, :timeout} end)

      assert {:error, {:classifier_failed, :timeout}} =
               Scorer.score(@prompt, [:coder], :llm, %{classifier: :mock})
    end

    test "un clasificador registrado pero APAGADO no se usa" do
      # `enable_llm_classifier = false` tiene que significar algo: existe y no
      # se usa, que es distinto de no existir. `Apagado.classify/2` revienta,
      # asi que un `:miss` aqui prueba que no llego a llamarse.
      :ok = Classifier.register(:apagado, Apagado)

      assert Scorer.score(@prompt, [:coder], :llm, %{
               classifier: :apagado,
               enable_llm_classifier: false
             }) == :miss
    end
  end

  # ── el ciclo ─────────────────────────────────────────────────────────────

  describe "un clasificador NO puede pedirle un modelo al router" do
    setup do
      put_model(:coder, [:chat, :code], "escribe codigo")
      :ok
    end

    test "el clasificador que llama al router reventa, en vez de iterar para siempre" do
      :ok = Classifier.register(:ciclico, Ciclico)

      # Sin guardia, un clasificador que llama al router es recursion infinita:
      # el router llama al clasificador, que llama al router, hasta que el proceso
      # muere
      # por stack y el sintoma es un crash que no habla de routers.
      assert_raise RuntimeError, ~r/directamente/i, fn ->
        Scorer.score(@prompt, [:coder], :llm, %{classifier: :ciclico})
      end
    end

    test "el fallo dice QUE HAY QUE HACER y a quien" do
      :ok = Classifier.register(:ciclico, Ciclico)

      error =
        assert_raise RuntimeError, fn ->
          Scorer.score(@prompt, [:coder], :llm, %{classifier: :ciclico})
        end

      # El clasificador lo escribe el usuario y no va a leer el codigo de
      # Candil: este mensaje es la documentacion, aqui.
      message = Exception.message(error)
      assert message =~ "Ciclico"
      assert message =~ "directamente"
    end

    test "la guardia esta en la puerta de entrada, no en la llamada al clasificador" do
      # Un clasificador puede llamar a `Router.route/2`, a `DecisionEngine` o a
      # lo que sea. Si la guardia viviera junto a la llamada al clasificador, un
      # bucle por otro camino pasaria sin verse.
      :ok = Classifier.register(:ciclico_directo, CiclicoDirecto)

      assert_raise RuntimeError, ~r/directamente/i, fn ->
        Scorer.score(@prompt, [:coder], :llm, %{classifier: :ciclico_directo})
      end
    end

    test "la guardia se levanta al salir y no envenena el proceso" do
      # En un servidor el proceso es el de siempre: si la bandera se quedara
      # puesta, el siguiente prompt del mismo consumidor reventaria sin motivo.
      :ok = Classifier.register(:sano, Sano)

      assert {:ok, [_], _reason} = Scorer.score(@prompt, [:coder], :llm, %{classifier: :sano})
      assert Scorer.classifying?() == false
      assert {:ok, [_], _reason} = Scorer.score(@prompt, [:coder], :llm, %{classifier: :sano})
    end

    test "fuera de un clasificador, la puerta sigue abierta de par en par" do
      # La guardia no puede cerrar el router entero: eso seria un router que no
      # enruta nunca.
      assert Scorer.classifying?() == false
    end
  end

  # ── la capa :embedding ───────────────────────────────────────────────────

  describe "la capa :embedding compara el prompt con la descripcion del modelo" do
    setup do
      put_model(:coder, [:chat, :code], "escribe codigo")
      put_model(:verifier, [:chat, :reasoning], "razona sobre codigo")
      put_model(:redactor, [:chat], "escribe prosa y explica")
      :ok = Adapter.register(:mock, AdapterMock)
      :ok
    end

    test "sin embedder registrado la capa NO existe, y no es un error" do
      # No hay embedder por defecto, por la misma razon que no hay clasificador
      # por defecto: uno por defecto decide, para todo el mundo y sin que nadie
      # lo pidiera, en que se calculan las distancias entre vectores.
      assert Adapter.default_embedder() == nil
      assert Scorer.score(@prompt, [:coder, :verifier], :embedding, %{}) == :miss
    end

    test "un embedder que dice que no soporta texto NO se usa" do
      stub(AdapterMock, :supports?, fn :text -> false end)

      assert Scorer.score(@prompt, [:coder], :embedding, %{embedder: :mock}) == :miss
    end

    test "ordena por similitud, no por el orden de los candidatos" do
      embedder(3)
      expect_embedder()

      # `verifier` va el primero y es el mas dissimilar. Si la capa no ordenase,
      # ganaria por posicion, y un test que pasara con el orden del consumidor
      # no estaria probando la similitud.
      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:verifier, :redactor, :coder], :embedding, %{
                 embedder: :mock
               })

      assert Enum.map(ranked, &elem(&1, 0)) == [:coder, :redactor, :verifier]
      assert [{:coder, best} | _] = ranked
      assert_in_delta best, 1.0, 0.0001
      # Y el ultimo es el que no se parece, con un 0 DE VERDAD: no es un 0
      # puesto por no saber comparar, que es la diferencia entre las dos capas.
      assert_in_delta ranked |> List.last() |> elem(1), 0.0, 0.0001
    end

    test "la similitud es coseno, y se nota" do
      embedder(3)
      expect_embedder()

      # [0.9, 0.1, 0] contra [1, 0, 0] vale 0.9938... y no 0.9: el coseno
      # divide por la norma. Es lo que hace comparables vectores de distinta
      # longitud, y lo que haria que "cuanto" (longitud) y "que" (direccion)
      # pesaran lo mismo.
      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:redactor, :coder], :embedding, %{embedder: :mock})

      assert [{:coder, 1.0}, {:redactor, near} | _] = ranked
      assert_in_delta near, 0.9938837, 0.0001
    end

    test "un prompt igual a una descripcion vale 1.0 y uno perpendicular vale 0.0" do
      embedder(3)

      expect(AdapterMock, :embed, fn _texts, _opts ->
        {:ok,
         [
           [1.0, 0.0, 0.0],
           [1.0, 0.0, 0.0],
           [0.0, 1.0, 0.0],
           [0.0, 0.0, 1.0]
         ]}
      end)

      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:coder, :verifier, :redactor], :embedding, %{
                 embedder: :mock
               })

      assert {:coder, +1.0} = hd(ranked)
      assert {:verifier, +0.0} = Enum.at(ranked, 1)
    end

    test "dimensiones que no cuadran son un error EXPLICITO, no un 0" do
      embedder(3)

      # `dimension/1` dice 3 y el embedder devuelve vectores de 5. Un 0.0 aqui
      # seria indistinguible de «no se parecen», y por tanto indistinguible de
      # «no se ha comparado nada». Es la misma mentira que da un stub.
      expect(AdapterMock, :embed, fn texts, _opts ->
        {:ok, Enum.map(texts, fn _t -> [1.0, 0.0, 0.0, 0.0, 0.0] end)}
      end)

      assert {:error, {:dimension_mismatch, expected: 3, got: 5}} =
               Scorer.score(@prompt, [:coder], :embedding, %{embedder: :mock})
    end

    test "vectores de distinta longitud entre si tambien es un error" do
      embedder(3)

      expect(AdapterMock, :embed, fn _texts, _opts ->
        {:ok, [[1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0]]}
      end)

      assert {:error, {:dimension_mismatch, expected: 3, got: 2}} =
               Scorer.score(@prompt, [:coder, :verifier], :embedding, %{embedder: :mock})
    end

    test "un modelo SIN descripcion no se compara, y no se le inventa una" do
      embedder(3)
      expect_embedder()
      put_model(:sin_desc, [:chat], nil)

      # Comparar con el alias, con el nombre del fichero o con un texto de
      # relleno seria comparar con algo que el usuario no escribio. Sin
      # descripcion, ese modelo no entra en la comparacion.
      assert {:ok, ranked, _reason} =
               Scorer.score(@prompt, [:sin_desc, :coder], :embedding, %{embedder: :mock})

      assert Enum.map(ranked, &elem(&1, 0)) == [:coder]
    end

    test "sin NINGUNA descripcion la capa devuelve :miss, no un 0 para todos" do
      put_model(:a, [:chat], nil)
      put_model(:b, [:chat], "")

      # Ni siquiera se llama al embedder: no hay nada que comparar, y gastarse
      # una inferencia para descobrirlo al final seria lo contrario de barato.
      assert Scorer.score(@prompt, [:a, :b], :embedding, %{embedder: :mock}) == :miss
    end

    test "un embedder que falla NO se confunde con «no se parece a nada»" do
      embedder(3)
      expect(AdapterMock, :embed, fn _texts, _opts -> {:error, :timeout} end)

      assert {:error, {:embeddings_failed, :timeout}} =
               Scorer.score(@prompt, [:coder], :embedding, %{embedder: :mock})
    end

    test "un embedder que devuelve mas o menos vectores de los pedidos se dice" do
      embedder(3)
      expect(AdapterMock, :embed, fn _texts, _opts -> {:ok, [[1.0, 0.0, 0.0]]} end)

      # Tres textos pedidos, un vector devuelto. Alinearlos por posicion seria
      # comparar el prompt con la descripcion de otro modelo, en silencio.
      assert {:error, {:embeddings_count_mismatch, 3, 1}} =
               Scorer.score(@prompt, [:coder, :verifier], :embedding, %{embedder: :mock})
    end

    test "un embedder que devuelve numeros donde deberia haber vectores se dice" do
      embedder(3)

      # `[1.0, 0.0, 0.0]` para UN texto parece un vector y es una lista de tres
      # numeros. Es el fallo que un `length/1` sin mirar no distingue.
      expect(AdapterMock, :embed, fn _texts, _opts -> {:ok, [1.0, [1.0, 0.0, 0.0]]} end)

      assert {:error, {:not_a_vector, 1.0}} =
               Scorer.score(@prompt, [:coder], :embedding, %{embedder: :mock})
    end

    test "el resultado se cachea: el prompt que se repite NO se vuelve a embeddear" do
      embedder(3)

      # Embeddear N descripciones en cada decision es carisimo, y un router que
      # paga una inferencia para decidir a quien se lo manda esta pagando el
      # doble. Es una decision de COSTE, no de exactitud: el vector de un texto
      # no cambia porque se haya pedido dos veces.
      expect(AdapterMock, :embed, 1, fn texts, _opts ->
        {:ok, Enum.map(texts, fn text -> Map.fetch!(@vectors, text) end)}
      end)

      settings = %{embedder: :mock}

      assert {:ok, _primera, _} = Scorer.score(@prompt, [:coder, :verifier], :embedding, settings)
      assert {:ok, _segunda, _} = Scorer.score(@prompt, [:coder, :verifier], :embedding, settings)
    end

    test "la cache guarda POR TEXTO: un prompt nuevo si se embeddea" do
      embedder(3)
      otro = [%{role: "user", content: "escribe un poema"}]

      vectors = Map.put(@vectors, "escribe un poema", [0.0, 1.0, 0.0])

      # La segunda llamada solo trae UN texto nuevo: las descripciones estan en
      # la cache. Si no lo estuvieran, serian dos y esta asercion no distinguiria
      # una cache de un no-cache.
      expect(AdapterMock, :embed, 2, fn texts, _opts ->
        {:ok, Enum.map(texts, fn text -> Map.fetch!(vectors, text) end)}
      end)

      settings = %{embedder: :mock}

      assert {:ok, _, _} = Scorer.score(@prompt, [:coder], :embedding, settings)
      assert {:ok, _, _} = Scorer.score(otro, [:coder], :embedding, settings)
    end

    test "la cache es POR EMBEDDER: dos embedders no comparten vectores" do
      :ok = Adapter.register(:otro, AdapterMock)
      embedder(3)

      # El mismo modulo mock, distinto nombre. Si la cache nociera del
      # embedder, la segunda decision se serviria con vectores del primero.
      expect(AdapterMock, :embed, 2, fn texts, _opts ->
        {:ok, Enum.map(texts, fn _t -> [0.0, 0.0, 1.0] end)}
      end)

      assert {:ok, _, _} = Scorer.score(@prompt, [:coder], :embedding, %{embedder: :mock})
      assert {:ok, _, _} = Scorer.score(@prompt, [:coder], :embedding, %{embedder: :otro})
    end
  end

  # ── el dato que hace falta: la descripcion ───────────────────────────────

  describe "el modelo tiene descripcion" do
    test "es un campo de verdad, y por defecto no esta" do
      assert %Model{description: "escribe codigo"} =
               %Model{alias: :x, type: :local, description: "escribe codigo"}

      assert %Model{description: nil} = %Model{alias: :x, type: :local}
    end
  end

  # ── utillaje ─────────────────────────────────────────────────────────────

  defp put_model(alias, usage, description) do
    # La lista mezcla endpoints y capacidades a proposito: estos tests comprueban
    # de paso que la separacion de `usage` funciona. La logica vive en un solo
    # sitio, `Model.split_usage/1`.
    {endpoints, capacidades, invalidos} = Model.split_usage(usage)

    if invalidos != [],
      do: flunk("usage con valores que no existen: #{inspect(invalidos)}")

    :ok =
      Store.register_model(%Model{
        alias: alias,
        type: :local,
        engine: :llama_cpp,
        usage: endpoints,
        capabilities: capacidades,
        description: description,
        model_dir: "/models",
        filename: "#{alias}.gguf"
      })
  end

  # Un embedder que responde con los vectores de la tabla. Los stubs de
  # `supports?/1` y `dimension/1` NO van aqui a proposito: cada test pone los
  # suyos, porque uno de ellos necesita un embedder que diga que no, y en Mox un
  # segundo `stub/3` no gana al primero.
  defp expect_embedder do
    expect(AdapterMock, :embed, fn texts, _opts ->
      {:ok, Enum.map(texts, fn text -> Map.fetch!(@vectors, text) end)}
    end)
  end

  defp embedder(dimension) do
    stub(AdapterMock, :supports?, fn :text -> true end)
    stub(AdapterMock, :dimension, fn _opts -> dimension end)
  end

  defp clear_registries do
    for table <- [:candil_router_classifiers, :candil_embeddings_adapters],
        :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  defmodule Apagado do
    @moduledoc """
    Registrado y apagado. `classify/2` **no** se puede llamar sin reventar, que
    es lo que hace util al test: si la capa lo llamara, el test caeria.
    """
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts), do: raise("este clasificador esta apagado")

    @impl true
    def name, do: :apagado

    @impl true
    def enabled?(opts), do: Keyword.get(opts, :enable_llm_classifier, false)
  end

  defmodule Ciclico do
    @moduledoc """
    Un clasificador que hace lo que NO hay que hacer: pedirle un modelo al
    router para poder clasificar. Es el bucle entero metido en un modulo.
    """
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts) do
      # El router llama al clasificador; el clasificador llama al router.
      Router.route([%{role: "user", content: "hola"}], candidates: [:coder])

      {:ok, %{difficulty: :normal, confidence: 1.0, why: "nunca se llega aqui"}}
    end

    @impl true
    def name, do: :ciclico

    @impl true
    def enabled?(_opts), do: true
  end

  defmodule CiclicoDirecto do
    @moduledoc "El mismo bucle, pero por la puerta de al lado."
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts) do
      DecisionEngine.decide([%{role: "user", content: "hola"}], [:coder], [])

      {:ok, %{difficulty: :normal, confidence: 1.0, why: "nunca se llega aqui"}}
    end

    @impl true
    def name, do: :ciclico_directo

    @impl true
    def enabled?(_opts), do: true
  end

  defmodule Sano do
    @moduledoc "Un clasificador que contesta lo que se le pregunta y no llama a nadie."
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts) do
      {:ok, %{difficulty: :normal, confidence: 0.8, why: "sin nada"}}
    end

    @impl true
    def name, do: :sano

    @impl true
    def enabled?(_opts), do: true
  end
end
