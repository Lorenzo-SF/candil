defmodule Candil.RAG.Store do
  @moduledoc """
  El almacén de los índices RAG: crea, guarda chunks con su embedding, busca
  por coseno y olvida. Un GenServer en el árbol que posee las tablas ETS,
  como `Candil.Agents.Snapshots`.

  ## Dos tablas

  - `:candil_rag_indexes` — `name => %{strategy:, embedder:, created_at:}`
  - `:candil_rag_chunks` — `{name, chunk_id} => %Chunk{}` (con embedding)

  Separarlas permite listar índices sin recorrer todos los chunks, y borrar
  un índice sin recorrer la tabla de chunks entera (aunque se hace un match
  por prefijo, que es lo que ETS permite).
  """

  use GenServer

  alias Candil.RAG.Chunk

  @indexes_table :candil_rag_indexes
  @chunks_table :candil_rag_chunks

  @doc false
  @spec indexes_table() :: atom()
  def indexes_table, do: @indexes_table

  @doc false
  @spec chunks_table() :: atom()
  def chunks_table, do: @chunks_table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── indexes ─────────────────────────────────────────────────────────────

  @doc "Crea un índice. Devuelve `{:error, :already_exists}` si ya existe."
  @spec create_index(Candil.RAG.index_name(), keyword()) :: :ok | {:error, :already_exists}
  def create_index(name, opts \\ []) when is_binary(name) do
    case :ets.lookup(@indexes_table, name) do
      [] ->
        :ets.insert(
          @indexes_table,
          {name,
           %{
             strategy: Keyword.get(opts, :strategy, :sentence),
             embedder: Keyword.get(opts, :embedder),
             created_at: System.system_time(:second)
           }}
        )

        :ok

      [_] ->
        {:error, :already_exists}
    end
  end

  @doc "Borra un índice y todos sus chunks."
  @spec drop_index(Candil.RAG.index_name()) :: :ok
  def drop_index(name) when is_binary(name) do
    :ets.delete(@indexes_table, name)
    :ets.match_delete(@chunks_table, {{name, :_}, :_})
    :ok
  end

  @doc "Lista los índices existentes."
  @spec list_indexes() :: [Candil.RAG.index_name()]
  def list_indexes do
    :ets.tab2list(@indexes_table)
    |> Enum.map(fn {name, _meta} -> name end)
    |> Enum.sort()
  end

  @doc "Metadata de un índice, o `:error` si no existe."
  @spec get_index(Candil.RAG.index_name()) :: {:ok, map()} | {:error, :not_found}
  def get_index(name) when is_binary(name) do
    case :ets.lookup(@indexes_table, name) do
      [{_name, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  # ── chunks ──────────────────────────────────────────────────────────────

  @doc "Guarda una lista de chunks en un índice. Reemplaza los que tengan el mismo id."
  @spec put_chunks(Candil.RAG.index_name(), [Chunk.t()]) :: :ok
  def put_chunks(name, chunks) when is_binary(name) and is_list(chunks) do
    Enum.each(chunks, fn %Chunk{id: id} = chunk ->
      :ets.insert(@chunks_table, {{name, id}, chunk})
    end)

    :ok
  end

  @doc "Los chunks de un índice."
  @spec get_chunks(Candil.RAG.index_name()) :: [Chunk.t()]
  def get_chunks(name) when is_binary(name) do
    :ets.match_object(@chunks_table, {{name, :_}, :_})
    |> Enum.map(fn {_key, chunk} -> chunk end)
  end

  @doc "Cantidad de chunks de un índice."
  @spec count_chunks(Candil.RAG.index_name()) :: non_neg_integer()
  def count_chunks(name) when is_binary(name) do
    :ets.match_object(@chunks_table, {{name, :_}, :_})
    |> length()
  end

  @doc """
  Borra los chunks de un indice cuyo id **no** esta en `keep_ids`.

  Es lo que hace que reindexar un documento **no deje restos** ✓: si el
  documento cambio y ahora tiene tres chunks en vez de cinco ✓, los dos
  viejos desaparecen ✓ en vez de quedarse ahi competediendo con los
  nuevos ✓.

  Devuelve **cuantos** borro ✓, para que quien llama pueda decirlo ✓.
  """
  @spec delete_missing_chunks(Candil.RAG.index_name(), [binary()]) :: non_neg_integer()
  def delete_missing_chunks(name, keep_ids) when is_binary(name) and is_list(keep_ids) do
    keep = MapSet.new(keep_ids)

    @chunks_table
    |> :ets.match_object({{name, :_}, :_})
    |> Enum.reduce(0, fn {{_name, id}, _chunk}, acc ->
      if MapSet.member?(keep, id) do
        acc
      else
        :ets.delete(@chunks_table, {name, id})
        acc + 1
      end
    end)
  end

  @doc """
  Borra todos los indices y todos sus chunks.

  Para tests ✓ y para empezar de cero ✓. No borra la configuracion ✓ —eso es
  otra cosa ✓— ni los ficheros ✓.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@indexes_table)
    :ets.delete_all_objects(@chunks_table)
    :ok
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@indexes_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@chunks_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
