defmodule Candil.RAG.Chunk do
  @moduledoc """
  One retrievable piece of a document.

  `position` is kept so a result can be cited as "paragraph 4" rather than as
  an opaque id. A RAG answer you cannot point at is an answer you cannot
  check.
  """

  @enforce_keys [:id, :text]
  defstruct id: nil,
            text: nil,
            document_id: nil,
            position: nil,
            embedding: nil,
            metadata: %{},
            score: nil

  @type t :: %__MODULE__{
          id: binary(),
          text: binary(),
          document_id: binary() | nil,
          position: non_neg_integer() | nil,
          embedding: [float()] | nil,
          metadata: map(),
          score: float() | nil
        }
end

defmodule Candil.RAG do
  @moduledoc """
  Chunking, indexing, retrieval and reranking over documents.

  ## Hybrid retrieval with RRF, not a sum of scores

  BM25 and cosine similarity produce numbers on different scales. Adding them
  needs calibration that nothing here can do for you, and a miscalibrated sum
  silently favours whichever system happens to score higher. Reciprocal Rank
  Fusion uses only the **rank** of a document in each list, not its score, so
  it needs no calibration and works on the first run.

  ## Cosine over a linear scan, up to about 50k chunks

  Below that, a linear scan is faster than any index you would have to build.
  Above it, the Postgres backend with pgvector. There is no in-memory HNSW
  here on purpose: for 50k documents the index costs more to build than it
  saves, and the honest answer at that size is a real database.

  ## Rerank is optional and never the default

  A cross-encoder reranker is roughly a hundred times the cost of the
  retrieval it reranks. It is opt-in, and with nothing configured the results
  come back in retrieval order.
  """

  alias Candil.RAG.Chunk

  @type index_name :: binary()
  @type backend :: :memory | :postgres

  @typedoc """
  Chunking strategies.

  `sentence` is the default because it is the one that respects meaning at
  the boundary. `fixed` splits at a token count and is a fallback, not an
  improvement.
  """
  @type strategy :: :sentence | :paragraph | :fixed

  @doc """
  Creates an index.

  Not implemented until phase 6; the options are the contract.
  """
  @spec create_index(index_name(), keyword()) :: :ok | {:error, term()}
  def create_index(name, opts \\ []) do
    Candil.RAG.Store.create_index(name, opts)
  end

  @doc """
  Indexes a directory of files, or a single piece of text.

  Returns how many chunks were indexed.
  """
  @spec index(index_name(), binary(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def index(name, path_or_text, opts \\ []) do
    case Candil.RAG.Store.get_index(name) do
      {:error, :not_found} -> {:error, :index_not_found}
      {:ok, meta} -> do_index(name, path_or_text, opts, meta)
    end
  end

  defp do_index(name, path_or_text, opts, meta) do
    text = resolve_text(path_or_text)
    strategy = Keyword.get(opts, :strategy, meta.strategy)
    document_id = Keyword.get(opts, :document_id, name)

    chunks = Candil.RAG.Chunker.chunk(text, strategy: strategy, document_id: document_id)

    chunks =
      enrich_chunks(
        chunks,
        Keyword.get(opts, :embeddings),
        Keyword.get(opts, :embedder, meta.embedder)
      )

    Candil.RAG.Store.put_chunks(name, chunks)
    {:ok, length(chunks)}
  end

  defp enrich_chunks(chunks, embeddings, _embedder)
       when is_list(embeddings) and length(embeddings) == length(chunks) do
    chunks
    |> Enum.zip(embeddings)
    |> Enum.map(fn {chunk, vec} -> %{chunk | embedding: vec} end)
  end

  defp enrich_chunks(chunks, _embeddings, nil), do: chunks

  defp enrich_chunks(chunks, _embeddings, embedder), do: embed_chunks(chunks, embedder)

  @doc """
  Searches an index.

  Returns the chunks that cleared the score, best first. Not implemented
  until phase 6.
  """
  @spec search(index_name(), binary(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}
  def search(name, query, opts \\ []) do
    case Candil.RAG.Store.get_index(name) do
      {:error, :not_found} -> {:error, :index_not_found}
      {:ok, meta} -> do_search(name, query, opts, meta)
    end
  end

  defp do_search(name, query, opts, meta) do
    chunks = Candil.RAG.Store.get_chunks(name)
    if chunks == [], do: {:ok, []}, else: rank_chunks(chunks, query, opts, meta)
  end

  defp rank_chunks(chunks, query, opts, meta) do
    query_emb = resolve_query_embedding(query, opts, meta)
    has_emb = Enum.any?(chunks, &(&1.embedding != nil))

    if has_emb and query_emb == nil do
      {:error, :no_query_embedding}
    else
      min_score = Keyword.get(opts, :min_score, 0.0)
      limit = Keyword.get(opts, :limit, 5)

      results =
        chunks
        |> Enum.map(fn chunk -> %{chunk | score: score_chunk(chunk, query_emb)} end)
        |> Enum.filter(fn c -> c.score == nil or c.score >= min_score end)
        |> Enum.sort_by(fn c -> {-(c.score || 0.0), c.id} end)
        |> Enum.take(limit)

      {:ok, results}
    end
  end

  defp resolve_query_embedding(query, opts, meta) do
    case Keyword.get(opts, :embedding) do
      nil ->
        case embed_query(query, Keyword.get(opts, :embedder, meta.embedder)) do
          {:ok, vec} -> vec
          {:error, _} -> nil
        end

      vec ->
        vec
    end
  end

  defp score_chunk(%{embedding: emb}, query_emb) when emb != nil and query_emb != nil do
    cosine(emb, query_emb)
  end

  defp score_chunk(_chunk, _query_emb), do: nil

  @doc """
  Deletes an index.
  """
  @spec drop_index(index_name()) :: :ok | {:error, term()}
  def drop_index(name) do
    Candil.RAG.Store.drop_index(name)
  end

  @doc """
  Lists the indexes.
  """
  @spec list_indexes() :: [index_name()] | {:error, term()}
  def list_indexes do
    Candil.RAG.Store.list_indexes()
  end

  @doc """
  The model a RAG configuration says to embed with.

  The TOML gives a string and `Candil.Store` is keyed by atoms, so the
  conversion happens here rather than at every call site — a string that
  reaches a lookup finds nothing, and the failure looks like a missing model
  rather than a type mismatch.

  ## Examples

      # El modelo TIENE que estar en el Store: `embedder/1` pregunta al
      # catalogo, no a la tabla de atomos de la VM. Un alias que existe como
      # atomo pero no en el catalogo devuelve `{:error, {:unknown_embedder, _}}`,
      # y eso es lo que distingue esta funcion de un `String.to_existing_atom/1`.

      iex> Candil.RAG.embedder(%{})
      {:error, :no_embedder}

      iex> Candil.RAG.embedder(%{embedder: ""})
      {:error, :no_embedder}

      iex> Candil.RAG.embedder(%{embedder: "no-existe-en-el-catalogo"})
      {:error, {:unknown_embedder, "no-existe-en-el-catalogo"}}
  """
  @spec embedder(map()) :: {:ok, atom()} | {:error, :no_embedder | {:unknown_embedder, binary()}}
  def embedder(%{embedder: name}) when is_binary(name) and name != "" do
    # `String.to_existing_atom/1` NO es "comprobar que este modelo existe": es
    # "comprobar que este atomo ya se ha creado en la VM". Que un alias exista
    # como atomo y exista como modelo en el catalogo son DOS cosas, y el
    # test que documentaba esto se Greenberg: el resultado cambiaba con la
    # semilla, porque otro test habia creado el atomo antes.
    #
    # Por eso se pregunta al Store, que es donde vive el catalogo.
    # El toml es un fichero de texto y sus claves son strings. Crear un atomo
    # por cada clave que aparezca ahi es denegacion de servicio con un fichero
    # de configuracion en la mano. `to_existing_atom/1` ademas responde
    # `false` en vez de reventar cuando el nombre no existe.
    # `String.to_existing_atom/1` devuelve el ATOMO, no `{:ok, atomo}`. Empaquetarlo
    # en un `with` contra `{:ok, alias_}` lo manda siempre al `else`, y el
    # `{:ok, _}` que devuelve `Store.get_model/1` es de otra forma. Se comprueba
    # con un `case` en vez de encadenar dos formas distintas como si fueran la
    # misma.
    with alias_ <- String.to_existing_atom(name),
         true <- match?({:ok, _}, Candil.Store.get_model(alias_)) do
      {:ok, alias_}
    else
      _ -> {:error, {:unknown_embedder, name}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_embedder, name}}
  end

  def embedder(_config), do: {:error, :no_embedder}

  @doc """
  The Reciprocal Rank Fusion constant.

  Sixty, the value from the original paper. It damps the top of each list
  enough that one system being confidently wrong about a single document does
  not outvote the other system's whole list.
  """
  @spec rrf_k() :: pos_integer()
  def rrf_k, do: 60

  @doc """
  Fuses several ranked lists into one.

  Each input is a list of `{id, score}`, best first. The score is ignored;
  only the position counts. Ties break on the id so the result is stable.

  ## Examples

      iex> ranked = Candil.RAG.rrf([[{:a, 9.0}, {:b, 1.0}], [{:b, 9.0}]])
      iex> Enum.map(ranked, &elem(&1, 0))
      [:b, :a]

      iex> Candil.RAG.rrf([])
      []
  """
  @spec rrf([[{binary(), float()}]], pos_integer()) :: [{binary(), float()}]
  def rrf(rankings, k \\ rrf_k())

  def rrf([], _k), do: []

  def rrf(rankings, k) do
    scores =
      Enum.reduce(rankings, %{}, fn ranking, acc ->
        ranking
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {{id, _score}, rank}, inner ->
          Map.update(inner, id, 1.0 / (k + rank), &(&1 + 1.0 / (k + rank)))
        end)
      end)

    scores
    |> Enum.map(fn {id, score} -> {id, score} end)
    |> Enum.sort_by(fn {id, score} -> {-score, id} end)
  end

  @doc """
  Cosine similarity of two equal-length vectors.

  A zero vector has no direction, so the similarity is 0 rather than a
  division by zero.

  ## Examples

      iex> Candil.RAG.cosine([1.0, 0.0], [1.0, 0.0])
      1.0

      iex> Candil.RAG.cosine([1.0, 0.0], [0.0, 1.0])
      0.0
  """
  @spec cosine([float()], [float()]) :: float()
  def cosine([], []), do: 0.0

  def cosine(a, b) when length(a) != length(b) do
    raise ArgumentError,
          "cosine/2 needs vectors of equal length, got #{length(a)} and #{length(b)}"
  end

  def cosine(a, b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = a |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
    norm_b = b |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  # ── helpers privados ────────────────────────────────────────────────────

  defp resolve_text(path_or_text) when is_binary(path_or_text) do
    if File.exists?(path_or_text) and not File.dir?(path_or_text) do
      File.read!(path_or_text)
    else
      path_or_text
    end
  end

  defp embed_chunks(chunks, nil), do: chunks

  defp embed_chunks(chunks, embedder) do
    cfg = resolve_embedder(embedder)

    if cfg == nil do
      chunks
    else
      texts = Enum.map(chunks, & &1.text)

      case Candil.Embeddings.embed_batch(texts,
             url: cfg.url,
             model: cfg.model,
             api_key: cfg[:api_key]
           ) do
        {:ok, vectors} when is_list(vectors) and length(vectors) == length(chunks) ->
          chunks
          |> Enum.zip(vectors)
          |> Enum.map(fn {chunk, vec} -> %{chunk | embedding: vec} end)

        _ ->
          chunks
      end
    end
  end

  defp embed_query(_query, nil), do: {:error, :no_embedder}

  defp embed_query(query, embedder) do
    cfg = resolve_embedder(embedder)

    if cfg == nil do
      {:error, :no_embedder}
    else
      Candil.Embeddings.embed(query, url: cfg.url, model: cfg.model, api_key: cfg[:api_key])
    end
  end

  defp resolve_embedder(nil), do: nil

  defp resolve_embedder(embedder) when is_binary(embedder) do
    alias_ =
      try do
        String.to_existing_atom(embedder)
      rescue
        ArgumentError -> nil
      end

    case if alias_ != nil, do: Candil.Store.get_model(alias_), else: :error do
      {:ok, model} when model.type == :local ->
        case Candil.Store.get_engine(model.engine) do
          {:ok, engine} ->
            %{
              url: "http://#{engine.host}:#{engine.port}",
              model: to_string(model.alias),
              api_key: engine.api_key
            }

          _ ->
            %{url: "http://127.0.0.1:8080", model: embedder}
        end

      _ ->
        %{url: "http://127.0.0.1:8080", model: embedder}
    end
  end

  defp resolve_embedder(%{} = m), do: m

  defp resolve_embedder(_), do: nil
end
