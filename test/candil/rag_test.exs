defmodule Candil.RAGTest do
  use ExUnit.Case, async: true

  alias Candil.{Model, RAG, Store}
  alias Candil.RAG.Chunk

  doctest Candil.RAG

  describe "Reciprocal Rank Fusion" do
    test "uses rank, not score" do
      # The point of RRF: a document that scores 9 in one list and 1 in
      # another outranks one that scores 1 in both, because the scores are on
      # scales that were never comparable. Only the position counts.
      assert [{:b, _}, {:a, _}] = RAG.rrf([[{:a, 9.0}, {:b, 1.0}], [{:b, 9.0}]])
    end

    test "a document found by both systems wins" do
      fused = RAG.rrf([[{:a, 1.0}, {:shared, 1.0}], [{:b, 1.0}, {:shared, 1.0}]])
      assert [{:shared, _}, {:a, _}, {:b, _}] = fused
    end

    test "an empty set of rankings is empty" do
      assert RAG.rrf([]) == []
    end

    test "a single ranking keeps its order" do
      assert [{:a, _}, {:b, _}] = RAG.rrf([[{:a, 5.0}, {:b, 4.0}]])
    end

    test "ties in the fused score break on the id, so the result is stable" do
      # A real tie needs the two documents to swap places across the lists:
      # a is 1st in one and 2nd in the other, b is 2nd and 1st. Both then
      # score 1/61 + 1/62 exactly, and the sort has to be total or two runs
      # over the same data disagree.
      a = RAG.rrf([[{:a, 1.0}, {:b, 1.0}], [{:b, 1.0}, {:a, 1.0}]])
      b = RAG.rrf([[{:b, 1.0}, {:a, 1.0}], [{:a, 1.0}, {:b, 1.0}]])

      assert [{:a, first}, {:b, second}] = a
      assert_in_delta first, second, 0.000001
      assert a == b
    end

    test "k damps the top of the list" do
      # k=60 means a single first place cannot outvote a document that both
      # systems agree is relevant.
      single = RAG.rrf([[{:solo, 100.0}]], 60)
      agreed = RAG.rrf([[{:pair, 1.0}, {:other, 1.0}], [{:pair, 1.0}]], 60)

      assert [{:solo, solo_score}] = single
      assert [{:pair, pair_score}, {:other, _} | _] = agreed
      assert pair_score > solo_score
    end
  end

  describe "cosine/2" do
    test "identical vectors are 1.0" do
      assert RAG.cosine([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) == 1.0
    end

    test "orthogonal vectors are 0.0" do
      assert RAG.cosine([1.0, 0.0], [0.0, 1.0]) == 0.0
    end

    test "a zero vector has no direction, so it is 0.0 not a crash" do
      assert RAG.cosine([0.0, 0.0], [1.0, 1.0]) == 0.0
      assert RAG.cosine([], []) == 0.0
    end

    test "mismatched lengths is an error, not a wrong number" do
      assert_raise ArgumentError, fn -> RAG.cosine([1.0], [1.0, 2.0]) end
    end
  end

  describe "embedder/1" do
    test "reads the configured model as an atom" do
      # El TOML da una string y el Store se indexa por atomos. Este test
      # REGISTRA los dos modelos porque `embedder/1` consulta al Store: que un
      # alias exista como atomo y exista en el catalogo son dos cosas, y
      # `String.to_existing_atom/1` solo comprobaba la primera.
      register(:embed)
      register(:coder)
      assert RAG.embedder(%{embedder: "embed"}) == {:ok, :embed}
      assert RAG.embedder(%{embedder: "coder"}) == {:ok, :coder}
    end

    test "an unknown name says so, and does not create an atom" do
      assert {:error, {:unknown_embedder, "inventado"}} =
               RAG.embedder(%{embedder: "inventado"})
    end

    test "says which thing is missing rather than failing later" do
      # "no_embedder" says what to go and set. A crash in the middle of a
      # search says nothing.
      assert RAG.embedder(%{}) == {:error, :no_embedder}
      assert RAG.embedder(%{embedder: nil}) == {:error, :no_embedder}
      assert RAG.embedder(%{embedder: ""}) == {:error, :no_embedder}
    end
  end

  describe "la busqueda sin embedder" do
    # Un indice con nombre unico ✓: las tablas del Store son globales ✓ y
    # este test es `async` ✓.
    defp unique_index, do: "test:#{System.unique_integer([:positive])}"

    test "encuentra el chunk por las palabras de la consulta" do
      name = unique_index()
      on_exit(fn -> RAG.drop_index(name) end)

      :ok = RAG.create_index(name)
      {:ok, 2} = RAG.index(name, "Quien decide el presupuesto. Quien aprueba el gasto.")

      assert {:ok, [chunk | _]} = RAG.search(name, "presupuesto")
      assert chunk.text =~ "presupuesto"
    end

    test "y sin embeddings NO se cae: la lexica siempre esta" do
      # El caso que motivó la fase: un RAG sin embedder no puede devolver
      # «no hay resultados» por no tener embedder — eso es un fallo, no una
      # respuesta. La busqueda sin significado es una busqueda peor, no una
      # busqueda nula.
      name = unique_index()
      on_exit(fn -> RAG.drop_index(name) end)

      :ok = RAG.create_index(name)
      {:ok, _} = RAG.index(name, "El presupuesto lo decide el director.")

      assert {:ok, results} = RAG.search(name, "presupuesto")
      assert results != []
    end

    test "reindexar un documento que encogio borra los chunks viejos" do
      name = unique_index()
      on_exit(fn -> RAG.drop_index(name) end)

      :ok = RAG.create_index(name)
      {:ok, 3} = RAG.index(name, "Uno. Dos. Tres.")

      assert Candil.RAG.Store.count_chunks(name) == 3

      # Ahora el documento tiene un solo chunk. Los otros dos tienen que
      # irse: si se quedan, compiten con el nuevo por el mismo documento.
      {:ok, 1} = RAG.index(name, "Uno.")

      assert Candil.RAG.Store.count_chunks(name) == 1
    end

    test "el RRF ordena: el chunk que encuentran las dos busquedas va primero" do
      name = unique_index()
      on_exit(fn -> RAG.drop_index(name) end)

      :ok = RAG.create_index(name)

      texto = "Quien decide el presupuesto. Quien decide el gasto."
      {:ok, 2} = RAG.index(name, texto)

      # El vector pone primero al segundo chunk (el del gasto) y la lexica al
      # primero (el del presupuesto). El que aparece en las dos busquedas
      # gana: es lo que RRF significa.
      {:ok, 2} =
        RAG.index(name, texto, embeddings: [[0.0, 1.0], [1.0, 0.0]])

      assert {:ok, [first | _]} = RAG.search(name, "presupuesto", embedding: [1.0, 0.0])
      assert first.text =~ "presupuesto"
    end

    test "un chunk que solo encuentra la lexica conserva SU score" do
      # Este test caza un bug que el review encontro: el mapa de scores era
      # **solo** el vectorial, asi que un chunk que solo aparecia en la lexica
      # se quedaba con `nil` -o con el 0.0 de un coseno- que no es lo que la
      # busqueda habia dicho.
      name = unique_index()
      on_exit(fn -> RAG.drop_index(name) end)

      :ok = RAG.create_index(name)

      texto = "Quien decide el presupuesto. Quien decide el gasto."

      # El segundo chunk **no** tiene embedding: solo lo encuentra la lexica.
      {:ok, 2} = RAG.index(name, texto, embeddings: [[0.0, 1.0], nil])

      assert {:ok, results} = RAG.search(name, "gasto", embedding: [1.0, 0.0])

      gasto = Enum.find(results, &(&1.text =~ "gasto"))
      assert gasto
      # Su score es el **solape** (1.0), no nil ni el 0.0 del vector.
      assert gasto.score == 1.0
    end
  end

  describe "Chunk" do
    test "requires an id and a text, and keeps the position for citation" do
      chunk = %Chunk{id: "c1", text: "hola", position: 4}
      assert chunk.position == 4
      assert_raise ArgumentError, fn -> struct!(Chunk, text: "sin id") end
    end

    test "a score is absent until retrieval sets it" do
      assert %Chunk{id: "c1", text: "t"}.score == nil
    end
  end

  defp register(alias) do
    :ok =
      Store.register_model(%Model{
        alias: alias,
        type: :local,
        engine: :llama_cpp,
        context_size: 8192,
        model_dir: "/tmp/#{alias}",
        filename: "#{alias}.gguf"
      })
  end
end
