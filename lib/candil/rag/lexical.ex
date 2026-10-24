defmodule Candil.RAG.Lexical do
  @moduledoc """
  La busqueda **lexica**: solape de tokens.

  ## Por que existe

  Un RAG sin embedder solo tiene una forma de buscar: **las palabras que se
  repiten** ✓. Y no es un plan B poorer: para una pregunta concreta —*«quien
  decide el presupuesto»*— el termino exacto suele estar **en el documento** ✓,
  mientras que el embedding lo difunde en un vector que a veces no se parece a
  nada ✓.

  ## Lo que NO hace

  No entiende **sinonimos** ✓: *«quien decide el presupuesto»* no encuentra
  *«quien aprueba el gasto»* ✓. Eso es lo que hace el embedder ✓, y por eso
  las dos busquedas se **fusionan** ✓ (`Candil.RAG.rrf/2` ✓) en vez de
  competir ✓.

  ## El score

  Es el **solape** dividido por los tokens de la consulta ✓: un chunk que
  contiene las tres palabras de la consulta puntua 1.0 ✓, uno que contiene una
  de tres, 0.33 ✓. Es una proporcion, no una frecuencia ✓: un chunk que
  repite la palabra diez veces no vale mas que uno que la dice una vez ✓ —
  repetir no es probar nada ✓.

  ## La forma

  Devuelve `[{id, score}]` ✓, la misma que `Candil.RAG.rrf/2` consume ✓.
  """

  alias Candil.RAG.Chunk

  @type ranking :: [{binary(), float()}]

  @doc """
  Puntúa los chunks por solape de tokens con la consulta.

  Solo devuelve los chunks con **algo** de solape ✓: un chunk sin una sola
  palabra de la consulta no es un resultado, es ruido ✓.

  Los empates se rompen por **id** ✓, para que el orden sea estable ✓: la
  misma consulta sobre el mismo indice devuelve siempre lo mismo ✓.
  """
  @spec rank([Chunk.t()], binary()) :: ranking()
  def rank(chunks, query) when is_list(chunks) and is_binary(query) do
    case tokenize(query) do
      [] ->
        []

      tokens ->
        chunks
        |> Enum.map(&score(&1, tokens))
        |> Enum.filter(fn {_id, score} -> score > 0.0 end)
        |> Enum.sort_by(fn {id, score} -> {-score, id} end)
    end
  end

  @doc """
  Los tokens de un texto: en minusculas y sin puntuacion.

  Los acentos **se quedan** ✓: *«café»* y *«cafe»* son tokens distintos ✓, y
  un indice en español los tiene en español ✓.

  ## Ejemplos

      iex> Candil.RAG.Lexical.tokenize("Hola, mundo!")
      ["hola", "mundo"]

      iex> Candil.RAG.Lexical.tokenize("  ")
      []
  """
  @spec tokenize(binary()) :: [binary()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
  end

  defp score(%Chunk{id: id, text: text}, query_tokens) do
    text_tokens = tokenize(text)
    overlap = Enum.count(query_tokens, &(&1 in text_tokens))

    {id, overlap / length(query_tokens)}
  end
end
