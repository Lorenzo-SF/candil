defmodule Candil.Router.TribunalTest do
  @moduledoc """
  La metrica del tribunal: **que fraccion de decisiones resolvio la politica**.

  `DISENO-MOTOR.md` §10 no deja meter un LLM como clasificador sin esto:
  *«se mide que fraccion de decisiones resolvio la politica. Si es el 97%, el
  LLM se llama el 3% y es ruido caro. Si es el 60%, el motor estatico esta mal
  hecho y hay que arreglarlo antes de meter un modelo.»*

  Y aqui esta la trampa que **ya se ha pagado una vez** con
  `[:candil, :policy, :turn]`, que `Destination` emite al tomar el turno y al
  soltarlo: una peticion que espera son dos eventos, no uno. Si el contador
  cuenta turnos donde deberia contar peticiones, el numero que sale no es un
  numero grande, es **otro numero**.

  El error twin aqui es peor, porque es silencioso: `decide_by/5` se puede
  llamar hasta cuatro veces en una peticion —reglas, embeddings, LLM— y emitir
  ahi contaria CAPAS. Un tribunal medido en capas dira que el motor estatico
  resolvio el 300%.
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

  @hola [%{role: "user", content: "hola"}]

  setup :verify_on_exit!

  setup do
    Cache.flush()
    Consumer.unpin(:tribunal)

    for table <- [:candil_router_classifiers, :candil_embeddings_adapters],
        :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    Scorer.flush_vector_cache()

    :ok = Candil.Store.register_engine(%CandilEngine{alias: :llama_cpp, binary: "llama-server"})

    listen()
  end

  defp listen do
    id = "tribunal-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:candil, :router, :decision],
      fn _name, measurements, meta, _config ->
        send(self(), {:decision, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  # Vacia lo acumulado. El `after` corto es lo que hace que "solo uno" sea una
  # afirmacion y no "uno de los que han llegado": si sobra alguno, el drainage
  # se lo lleva y el `length` lo delata.
  defp drain(acc \\ []) do
    receive do
      {:decision, measurements, meta} -> drain([{measurements, meta} | acc])
    after
      150 -> Enum.reverse(acc)
    end
  end

  describe "una decision, un evento" do
    setup do
      put_model(:coder, [:chat, :code], "escribe y arregla codigo")
      put_model(:verifier, [:chat, :reasoning], "razona y demuestra")
      put_model(:embed, [:embeddings], "convierte texto en vectores")

      :ok = Adapter.register(:mock, AdapterMock)
      stub(AdapterMock, :supports?, fn :text -> true end)
      stub(AdapterMock, :dimension, fn _opts -> 3 end)

      :ok = Classifier.register(:mock, ClassifierMock)
      stub(ClassifierMock, :enabled?, fn _opts -> true end)
      stub(ClassifierMock, :name, fn -> :mock end)

      with_router(embedder: "mock", classifier: "mock", enable_llm_classifier: true)
      :ok
    end

    test "una peticion que prueba reglas, embeddings y LLM emite UN evento" do
      # Las reglas no ven nada en "hola" y el embedder devuelve vectores que no
      # se parecen: las dos capas CORREN y las dos fallan. El LLM corre y gana.
      expect(AdapterMock, :embed, fn texts, _opts ->
        vectors = %{
          "hola" => [1.0, 0.0, 0.0],
          "escribe y arregla codigo" => [0.0, 1.0, 0.0],
          "razona y demuestra" => [0.0, 0.0, 1.0]
        }

        {:ok, Enum.map(texts, fn t -> Map.fetch!(vectors, t) end)}
      end)

      stub(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :normal, confidence: 0.9, why: "es un prompt normal"}}
      end)

      assert {:ok, _decision} = DecisionEngine.decide(@hola, [:coder, :verifier], [])

      events = drain()

      # Este es EL test. Tres capas ejecutadas, una peticion, un evento.
      assert length(events) == 1

      {_measurements, meta} = hd(events)
      assert meta.strategy == :llm
      # Y el rastro de capas dice las TRES, para que se vea que el uno no es
      # porque solo se ejecutara una.
      assert meta.layers_ran == [:rule, :embedding, :llm]
    end

    test "llm_called es verdad AUNQUE la decision no sea del LLM" do
      # El clasificador se ejecuta, paga su inferencia y NO pasa el umbral. La
      # decision es `:default`, y si un contador mirara solo `:strategy` diria
      # que el LLM no se llamo nunca — que es justo la mentira que lo hace caro.
      expect(AdapterMock, :embed, fn texts, _opts ->
        vectors = %{
          "hola" => [1.0, 0.0, 0.0],
          "escribe y arregla codigo" => [0.0, 1.0, 0.0],
          "razona y demuestra" => [0.0, 0.0, 1.0]
        }

        {:ok, Enum.map(texts, fn t -> Map.fetch!(vectors, t) end)}
      end)

      stub(ClassifierMock, :classify, fn _m, _o ->
        {:ok, %{difficulty: :deep, confidence: 0.1, why: "no me atrevo"}}
      end)

      assert {:ok, decision} = DecisionEngine.decide(@hola, [:coder, :verifier], [])

      events = drain()
      assert length(events) == 1

      {_measurements, meta} = hd(events)
      assert decision.strategy == :default
      assert meta.strategy == :default
      # El LLM se llamo. Eso es lo que hay que contar para el coste.
      assert meta.llm_called == true
      assert :llm in meta.layers_ran
    end
  end

  describe "la capa que produjo la decision" do
    setup do
      put_model(:coder, [:chat, :code], "escribe y arregla codigo")
      put_model(:verifier, [:chat, :reasoning], "razona y demuestra")
      :ok
    end

    test "una regla que gana se anuncia como :rule, sin LLM" do
      with_router(enable_llm_classifier: true)

      # Dos candidatos a proposito: con UNO solo, `pinned/3` contesta antes de
      # que corra ninguna capa —"este consumidor solo tiene un candidato"— y
      # la decision seria `:default` con las reglas sin consultar. Ese camino
      # tambien se prueba abajo, con sus dos candidatos.
      assert {:ok, _} =
               DecisionEngine.decide(
                 [
                   %{role: "user", content: "refactoriza este modulo y arregla el bug del codigo"}
                 ],
                 [:coder, :verifier],
                 []
               )

      events = drain()
      assert length(events) == 1

      {_measurements, meta} = hd(events)
      assert meta.strategy == :rule
      assert meta.model == :coder
      assert meta.llm_called == false
      assert meta.layers_ran == [:rule]
    end

    test "un solo candidato se anuncia como :default y sin tocar ninguna capa" do
      with_router(enable_llm_classifier: true)

      # El caso que se MidIO de verdad al medir: con un unico candidato la
      # decision es `:default`, no `:rule`. Contarlo como "la politica lo
      # resolvio" seria untrue: nadie hacomparedido nada, no habia donde elegir.
      assert {:ok, decision} = DecisionEngine.decide(@hola, [:coder], [])

      events = drain()
      assert length(events) == 1

      {_measurements, meta} = hd(events)
      assert decision.strategy == :default
      assert meta.strategy == :default
      assert meta.layers_ran == []
    end

    test "un forzado se anuncia como :forced y no consulta ninguna capa" do
      with_router(enable_llm_classifier: true)

      assert {:ok, decision} = DecisionEngine.decide(@hola, [:coder], force_model: :coder)

      events = drain()
      assert length(events) == 1

      {_measurements, meta} = hd(events)
      assert decision.strategy == :forced
      assert meta.strategy == :forced
      # `--model` gana a TODO y el resto ni se mira: no hay capas en el rastro.
      assert meta.layers_ran == []
    end

    test "la cache es una capa consultada, aunque la decision guardada diga :rule" do
      with_router(enable_cache: true, enable_llm_classifier: false)

      msgs = [%{role: "user", content: "refactoriza este modulo y arregla el bug del codigo"}]
      opts = [consumer: :tribunal, candidates: [:coder, :verifier]]

      # Por `Router.route/2` y no por `decide/3`: es el quien mete la decision
      # en la cache. `decide/3` no la guarda, y un test de la cache que no pasa
      # por el camino que la escribe no esta probando la cache.
      assert {:ok, primera} = Router.route(msgs, opts)
      assert primera.strategy == :rule
      assert length(drain()) == 1

      assert {:ok, segunda} = Router.route(msgs, opts)

      events = drain()
      assert length(events) == 1
      {_measurements, meta} = hd(events)

      # Aqui hay DOS hechos, y no son el mismo:
      #
      #  · `strategy` sigue siendo `:rule` porque `Cache.get/2` devuelve la
      #    decision guardada tal cual. El tipo `strategy` declara `:cache` y
      #    NADA en `lib/` lo produce nunca. Cambiarlo es cambiar lo que ya
      #    ven los `if strategy == ...` de fuera, y eso no es instrumentacion.
      #
      #  · `layers_ran` si dice `[ :cache ]`, porque en ESTA peticion no corrio
      #    ninguna regla. Sin esto, el evento contaria un acierto de la capa
      #    de reglas donde no hubo regla, que es la forma exacta de que el
      #    tribunal diga un numero que no se ha medido.
      assert segunda.strategy == :rule
      assert meta.layers_ran == [:cache]
      assert meta.llm_called == false

      # Y el prompt se puede repetir mil veces sin que el numero de "la politica
      # lo resolvio" suba: son decisiones que no se han vuelto a decidir.
      assert meta.strategy != :cache
    end
  end

  describe "lo que NO cuenta" do
    setup do
      put_model(:coder, [:chat, :code], "escribe y arregla codigo")
      put_model(:verifier, [:chat, :reasoning], "razona y demuestra")
      :ok
    end

    test "una peticion que no decidio no emite, para no llenar el denominador" do
      with_router(enable_llm_classifier: true)

      # Sin candidatos no hay decision, y una peticion que no decidio no es
      # una peticion que el tribunal pueda contar.
      assert {:error, :no_models_for_consumer} = DecisionEngine.decide(@hola, [], [])

      assert drain() == []
    end

    test "el rastro de capas no se filtra a la decision siguiente" do
      with_router(enable_llm_classifier: false)

      # Una peticion que no decide del todo, y despues otra normal. Si el
      # rastro de `layers_ran` se quedara en el proceso, esta segunda
      # decision saldria con las capas de la primera.
      assert {:error, :no_models_for_consumer} = DecisionEngine.decide(@hola, [], [])

      assert {:ok, _} =
               DecisionEngine.decide(
                 [%{role: "user", content: "arregla este bug del codigo del modulo"}],
                 [:coder, :verifier],
                 []
               )

      events = drain()
      assert length(events) == 1
      {_measurements, meta} = hd(events)
      assert meta.layers_ran == [:rule]
    end
  end

  describe "el evento sale por los dos namespaces" do
    test "un host que solo mira Arrea tambien lo ve" do
      id = "tribunal-arrea-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:arrea, :candil_router_decision],
        fn _name, _m, _meta, _config -> send(self(), :arrea) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      put_model(:coder, [:chat, :code], "escribe y arregla codigo")
      with_router(enable_llm_classifier: true)

      assert {:ok, _} =
               DecisionEngine.decide(
                 [%{role: "user", content: "arregla el bug del codigo"}],
                 [:coder, :verifier],
                 []
               )

      assert_receive :arrea
    end
  end

  defp put_model(alias, usage, description) do
    # La lista mezcla endpoints y capacidades a proposito: estos tests comprueban
    # de paso que la separacion de `usage` funciona. La logica vive en un solo
    # sitio, `Model.split_usage/1`.
    {endpoints, capacidades, invalidos} = Model.split_usage(usage)

    if invalidos != [],
      do: flunk("usage con valores que no existen: #{inspect(invalidos)}")

    :ok =
      Candil.Store.register_model(%Model{
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

  defp with_router(router) do
    tmp = Path.join(System.tmp_dir!(), "candil-tribunal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    flags = Enum.map_join(router, "\n", fn {key, value} -> "#{key} = #{inspect(value)}" end)

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
end
