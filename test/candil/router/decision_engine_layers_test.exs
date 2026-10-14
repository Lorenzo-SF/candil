defmodule Candil.Router.DecisionEngineLayersTest do
  @moduledoc """
  Las dos capas nuevas, vistas desde el motor.

  `scorer_layers_test.exs` prueba la capa. Este fichero prueba lo que cambia
  ARRIBA: que `DecisionEngine` usa de verdad lo que la capa devuelve, en vez de
  mirar `:miss` y tirar el resultado.

  Y en particular, las dos cosas que con una capa de stub no se podian
  comprobar: que un `:unknown` **no** rompe el enrutado, y que un `:deep` sin
  modelo de razonamiento **no** se cuela como si hubiera filtrosado algo.

  Los flags salen de un `candil.toml` de verdad escrito en un temporal, porque
  `enable_llm_classifier` se lee de `[router]` y no de unas constantes.
  """

  use Candil.StoreCase
  import Mox

  alias Candil.Embeddings.{Adapter, AdapterMock}
  alias Candil.Engine, as: CandilEngine
  alias Candil.Model
  # `alias Candil.Router.{..., Router}` daria `Candil.Router.Router`: en la
  # lista el nombre se ANADE al namespace, no lo nombra.
  alias Candil.Router, as: Router
  alias Candil.Router.{Cache, Classifier, ClassifierMock, Consumer, DecisionEngine}
  alias Candil.Router.Scorer, as: Scorer
  # Los clasificadores de prueba van los ultimos porque Credo ordena por el
  # nombre COMPLETO, y el de uno anidado es `Candil.Router.<Este>.Ciclico`.
  alias __MODULE__.Ciclico

  @nada [%{role: "user", content: "hola"}]

  setup :verify_on_exit!

  setup do
    Cache.flush()
    Consumer.unpin(:capas)

    for table <- [:candil_router_classifiers, :candil_embeddings_adapters],
        :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    Scorer.flush_vector_cache()

    :ok =
      Store.register_engine(%CandilEngine{alias: :llama_cpp, binary: "llama-server"})

    :ok
  end

  describe "la capa :llm, encendida" do
    setup do
      put_model(:coder, [:chat, :code], "escribe y arregla codigo")
      put_model(:verifier, [:chat, :reasoning], "razona y demuestra")

      :ok = Classifier.register(:mock, ClassifierMock)
      stub(ClassifierMock, :enabled?, fn _opts -> true end)
      stub(ClassifierMock, :name, fn -> :mock end)

      stub(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :normal, confidence: 0.9, why: "es un prompt normal"}}
      end)

      with_router(classifier: "mock", enable_llm_classifier: true)
      :ok
    end

    test "gana cuando su confianza pasa el umbral, y DICE que es la capa :llm" do
      assert {:ok, decision} =
               DecisionEngine.decide(@nada, [:coder, :verifier], force_strategy: :llm)

      assert decision.strategy == :llm
      # La confianza TAL CUAL, sin normalizar: lo que decide el umbral de
      # `confidence_threshold` es el numero del clasificador.
      assert decision.score == 0.9
      assert decision.reason =~ "es un prompt normal"
    end

    test "una confianza por debajo del umbral NO es una decision" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :normal, confidence: 0.2, why: "poco seguro"}}
      end)

      assert {:ok, decision} =
               DecisionEngine.decide(@nada, [:coder, :verifier], force_strategy: :llm)

      # Cayo al default. Un clasificador inseguro NO puede forzar al motor: la
      # confianza es suya, y el umbral es del motor.
      assert decision.strategy == :default
      assert decision.reason =~ "no layer cleared"
    end

    test "un clasificador que NO sabe NO rompe el enrutado" do
      expect(ClassifierMock, :classify, fn _m, _o -> {:error, :unknown} end)

      # Esto es lo que el `@moduledoc` del clasificador prohibe: confundir
      # `:unknown` con un fallo. Si aqui devolviera un error, un clasificador
      # timido dejaria al router sin decidir, que es justo cuando mas lo
      # necesita.
      assert {:ok, decision} = Router.route(@nada, candidates: [:coder, :verifier])

      assert decision.strategy == :default
      assert decision.model_alias == :verifier
    end

    test ":deep sin modelo de razonamiento NO manda a uno que no lo es" do
      # Un catalogo SIN `:reasoning` en ninguno de sus dos candidatos, que es
      # el caso que hace falta: con `verifier` de por medio el filtro tendria
      # algo que conservar y el test no probaria nada.
      put_model(:plano, [:chat], "charla de lo que sea")

      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :deep, confidence: 0.95, why: "esto es dificil"}}
      end)

      assert {:ok, decision} =
               DecisionEngine.decide(@nada, [:coder, :plano], force_strategy: :llm)

      # :deep y ningun `:reasoning` en el catalogo. La capa devuelve `:miss`,
      # y el motor cae al default. Lo que NO puede pasar es que `coder` gane
      # con estrategia :llm: ese 0.95 seria una decision tomada sin mirar.
      assert decision.strategy == :default
    end

    test ":deep con uno de razonamiento manda a ESE, no al primero de la lista" do
      expect(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :deep, confidence: 0.9, why: "hace falta pensar"}}
      end)

      assert {:ok, decision} =
               DecisionEngine.decide(@nada, [:coder, :verifier], force_strategy: :llm)

      assert decision.strategy == :llm
      assert decision.model_alias == :verifier
      assert decision.alternatives == []
    end
  end

  describe "la capa :llm, encendida y sin modelo" do
    setup do
      # Dos modelos, porque con uno solo el motor se para antes: un unico
      # candidato no es una decision, es que no habia donde elegir.
      put_model(:uno, [:embeddings], "vectores")
      put_model(:dos, [:embeddings], "vectores")
      with_router(classifier: "mock", enable_llm_classifier: true)
      :ok
    end

    test "el error lleva el modelo que se buscaba, y revienta en vez de degradar" do
      :ok = Classifier.register(:mock, ClassifierMock)
      stub(ClassifierMock, :enabled?, fn _ -> true end)

      # Un router que se rompe cuando le falta algo es preferible a uno que
      # responde mal y no lo dice: sin esto, la capa que el usuario encendio
      # lleva semanas sin hacer nada y nadie se entera.
      assert {:classifier_unavailable, error} =
               DecisionEngine.decide(@nada, [:uno, :dos], [])

      assert error.reason == :no_classifier_model
    end
  end

  describe "la capa :embedding" do
    setup do
      put_model(:coder, [:chat, :code], "escribe y arregla codigo")
      put_model(:redactor, [:chat], "escribe prosa y explica")
      # El motor se salta la capa de embeddings cuando NINGUN modelo sabe
      # embeddear, y lo marca como degradada. Sin este, el test de las
      # dimensiones estaria probando que la capa no corre.
      put_model(:embed, [:embeddings], "convierte texto en vectores")
      :ok = Adapter.register(:mock, AdapterMock)
      stub(AdapterMock, :supports?, fn :text -> true end)
      stub(AdapterMock, :dimension, fn _opts -> 3 end)
      with_router(embedder: "mock")
      :ok
    end

    test "ordena por similitud y gana la que se parece" do
      expect(AdapterMock, :embed, fn texts, _opts ->
        vectors = %{
          "hola" => [1.0, 0.0, 0.0],
          "escribe y arregla codigo" => [1.0, 0.0, 0.0],
          "escribe prosa y explica" => [0.0, 1.0, 0.0]
        }

        {:ok, Enum.map(texts, fn text -> Map.fetch!(vectors, text) end)}
      end)

      assert {:ok, decision} =
               DecisionEngine.decide(@nada, [:redactor, :coder], force_strategy: :embedding)

      assert decision.strategy == :embedding
      assert decision.model_alias == :coder
      assert decision.score == 1.0
    end

    test "una similitud por debajo del umbral NO es una decision" do
      expect(AdapterMock, :embed, fn texts, _opts ->
        vectors = %{
          "hola" => [1.0, 0.0, 0.0],
          "escribe y arregla codigo" => [0.0, 1.0, 0.0],
          "escribe prosa y explica" => [0.0, 0.0, 1.0]
        }

        {:ok, Enum.map(texts, fn text -> Map.fetch!(vectors, text) end)}
      end)

      assert {:ok, decision} =
               DecisionEngine.decide(@nada, [:redactor, :coder], force_strategy: :embedding)

      assert decision.strategy == :default
    end

    test "dimensiones que no cuadran PARAN el enrutado, no dan un 0" do
      expect(AdapterMock, :embed, fn texts, _opts ->
        {:ok, Enum.map(texts, fn _t -> [1.0, 0.0] end)}
      end)

      # Un 0.0 aqui seria indistinguible de «el prompt no se parece a nada», y
      # el router seguiria hacia abajo como si la capa hubiera opinado. Un
      # desajuste de dimensiones es un problema de configuracion, y se dice.
      assert {:error, {:dimension_mismatch, expected: 3, got: 2}} =
               Router.route(@nada, candidates: [:coder, :redactor])
    end
  end

  describe "el bucle, por la puerta del motor" do
    test "un clasificador que llama al router no puede quedarse llamando para siempre" do
      put_model(:coder, [:chat, :code], "escribe codigo")
      :ok = Classifier.register(:ciclico, Ciclico)
      with_router(classifier: "ciclico", enable_llm_classifier: true)

      # El bucle entero por la puerta de verdad, con el flag encendido y todo.
      # Si la guardia no estuviera, esto seria una recursion infinita y el
      # test tardaria mas de lo que tarda.
      assert_raise RuntimeError, ~r/directamente/i, fn ->
        Router.route(@nada, candidates: [:coder, :verifier])
      end
    end
  end

  # ── utillaje ─────────────────────────────────────────────────────────────

  defp put_model(alias, usage, description) do
    # La lista de este helper **mezcla endpoints y capacidades** a proposito:
    # asi estos tests comprueban de paso que la migracion de `usage` a
    # `capabilities` funciona, sin tener que reescribirlos uno a uno.
    {endpoints, capacidades} =
      case Model.split_usage(usage) do
        {e, c, []} -> {e, c}
        {_e, _c, invalidos} -> flunk("usage con valores que no existen: #{inspect(invalidos)}")
      end

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

  # Los flags de `[router]` se leen de un fichero de verdad. Se escribe uno en
  # un temporal en vez de parchear `Router.settings/0`, porque un test que
  # comprueba la variable que quiere poner no esta probando la lectura.
  defp with_router(router) do
    tmp = Path.join(System.tmp_dir!(), "candil-capas-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    flags =
      Enum.map_join(router, "\n", fn {key, value} -> "#{key} = #{inspect(value)}" end)

    File.write!(
      Path.join(tmp, "candil.toml"),
      "[general]\ndata_dir = \"#{tmp}\"\n[router]\n#{flags}\n"
    )

    System.put_env("CANDIL_CONFIG", Path.join(tmp, "candil.toml"))

    on_exit(fn ->
      System.delete_env("CANDIL_CONFIG")
      File.rm_rf(tmp)
    end)

    :ok
  end

  defmodule Ciclico do
    @moduledoc "Un clasificador que pide un modelo al router. Es el bucle, entero."
    @behaviour Classifier

    @impl true
    def classify(_messages, _opts) do
      Router.route([%{role: "user", content: "hola"}], candidates: [:coder])

      {:ok, %{difficulty: :normal, confidence: 1.0, why: "nunca se llega aqui"}}
    end

    @impl true
    def name, do: :ciclico

    @impl true
    def enabled?(_opts), do: true
  end
end
