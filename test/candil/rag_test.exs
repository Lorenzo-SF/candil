defmodule Candil.RAGTest do
  use ExUnit.Case, async: true

  alias Candil.RAG
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
      # The TOML gives a string; Store is keyed by atoms.
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

  describe "phase 10 stubs" do
    test "are honest rather than pretending to work" do
      for call <- [
            fn -> RAG.create_index("x") end,
            fn -> RAG.index("x", "text") end,
            fn -> RAG.search("x", "query") end,
            fn -> RAG.drop_index("x") end,
            fn -> RAG.list_indexes() end
          ] do
        assert {:error, %Candil.Error{reason: :not_implemented}} = call.()
      end
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
end
