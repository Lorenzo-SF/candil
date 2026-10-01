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

  alias Candil.Error
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

  Not implemented until phase 10; the options are the contract.
  """
  @spec create_index(index_name(), keyword()) :: :ok | {:error, term()}
  def create_index(name, opts \\ []) do
    _ = {name, opts}
    {:error, Error.not_implemented("Candil.RAG.create_index/2", phase: 10)}
  end

  @doc """
  Indexes a directory of files, or a single piece of text.

  Returns how many chunks were indexed.
  """
  @spec index(index_name(), binary(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def index(name, path_or_text, opts \\ []) do
    _ = {name, path_or_text, opts}
    {:error, Error.not_implemented("Candil.RAG.index/3", phase: 10)}
  end

  @doc """
  Searches an index.

  Returns the chunks that cleared the score, best first. Not implemented
  until phase 10.
  """
  @spec search(index_name(), binary(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}
  def search(name, query, opts \\ []) do
    _ = {name, query, opts}
    {:error, Error.not_implemented("Candil.RAG.search/3", phase: 10)}
  end

  @doc """
  Deletes an index.
  """
  @spec drop_index(index_name()) :: :ok | {:error, term()}
  def drop_index(name) do
    _ = name
    {:error, Error.not_implemented("Candil.RAG.drop_index/1", phase: 10)}
  end

  @doc """
  Lists the indexes.
  """
  @spec list_indexes() :: [index_name()] | {:error, term()}
  def list_indexes do
    {:error, Error.not_implemented("Candil.RAG.list_indexes/0", phase: 10)}
  end

  @doc """
  The model a RAG configuration says to embed with.

  The TOML gives a string and `Candil.Store` is keyed by atoms, so the
  conversion happens here rather than at every call site — a string that
  reaches a lookup finds nothing, and the failure looks like a missing model
  rather than a type mismatch.

  ## Examples

      iex> Candil.RAG.embedder(%{embedder: "embed"})
      {:ok, :embed}

      iex> Candil.RAG.embedder(%{})
      {:error, :no_embedder}

      iex> Candil.RAG.embedder(%{embedder: "no-existe-en-el-catalogo"})
      {:error, {:unknown_embedder, "no-existe-en-el-catalogo"}}
  """
  @spec embedder(map()) :: {:ok, atom()} | {:error, :no_embedder | {:unknown_embedder, binary()}}
  def embedder(%{embedder: name}) when is_binary(name) and name != "" do
    # The empty string is checked first because String.to_existing_atom("")
    # succeeds and returns :"" — a model alias that matches nothing, found by
    # the one lookup that should have rejected it.
    String.to_existing_atom(name)
  rescue
    ArgumentError -> {:error, {:unknown_embedder, name}}
  else
    alias_ -> {:ok, alias_}
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
end
