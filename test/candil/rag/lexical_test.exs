defmodule Candil.RAG.LexicalTest do
  @moduledoc """
  La busqueda **lexica**: buscar por las palabras.

  ## Que se comprueba aqui

  - Que encuentra el chunk que **comparte palabras** con la consulta ✓.
  - Que **no** devuelve chunks sin una sola palabra en comun ✓: un chunk que
    no tiene nada que ver es ruido ✓, y devolverlo baja la precision de todo
    lo demas ✓.
  - Que el score es el **solape** ✓, no la frecuencia ✓: repetir una palabra
    diez veces no vale mas que decirla una ✓.
  - Que el orden es **estable** ✓: los empates se rompen por id ✓.
  """

  use ExUnit.Case, async: true

  alias Candil.RAG.{Chunk, Lexical}

  defp chunk(id, text), do: %Chunk{id: id, text: text, position: 0, embedding: nil}

  describe "tokenize/1" do
    test "pasa a minusculas y quita la puntuacion" do
      assert Lexical.tokenize("Hola, mundo!") == ["hola", "mundo"]
    end

    test "un texto sin palabras no tiene tokens" do
      assert Lexical.tokenize("   ") == []
      assert Lexical.tokenize("!!!") == []
    end

    test "los acentos se quedan: el indice esta en español" do
      assert Lexical.tokenize("el café") == ["el", "café"]
    end
  end

  describe "rank/2" do
    test "encuentra el chunk que comparte palabras" do
      chunks = [
        chunk("a", "Quien decide el presupuesto del trimestre"),
        chunk("b", "Quien aprueba el gasto de la oficina")
      ]

      assert [{"a", score}] = Lexical.rank(chunks, "presupuesto")
      assert score == 1.0
    end

    test "el score es el solape, no la frecuencia" do
      chunks = [
        chunk("a", "presupuesto"),
        chunk("b", "presupuesto presupuesto presupuesto")
      ]

      assert [{"a", a_score}, {"b", b_score}] = Lexical.rank(chunks, "presupuesto")

      # Los dos comparten la misma palabra ✓, pero el que la repite tres
      # veces no vale mas ✓: repetir no es evidencia ✓.
      assert a_score == b_score
    end

    test "un chunk sin ninguna palabra en comun no se devuelve" do
      chunks = [chunk("a", "el presupuesto del trimestre")]

      assert Lexical.rank(chunks, "zapato") == []
    end

    test "una consulta sin palabras no encuentra nada" do
      chunks = [chunk("a", "el presupuesto")]

      assert Lexical.rank(chunks, "!!!") == []
    end

    test "los empates se rompen por id, para que el orden sea estable" do
      chunks = [chunk("b", "presupuesto"), chunk("a", "presupuesto")]

      assert [{"a", _}, {"b", _}] = Lexical.rank(chunks, "presupuesto")
    end

    test "una lista vacia devuelve una lista vacia" do
      assert Lexical.rank([], "presupuesto") == []
    end
  end
end
