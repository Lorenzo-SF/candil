defmodule Candil.Storage.ETS do
  @moduledoc """
  Adaptador de almacenamiento sobre ETS. El adaptador por defecto.

  La tabla es nombrada y pública, con concurrencia de lectura y escritura,
  igual que `Candil.Context`. El estado del adaptador es el nombre de la
  tabla: no hay proceso que mantener, solo la tabla.
  """

  @behaviour Candil.Storage.Adapter

  @default_table :candil_storage_ets

  @doc false
  @spec table() :: atom()
  def table, do: @default_table

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    {:ok, table}
  end

  @impl true
  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def put(table, key, value) do
    :ets.insert(table, {key, value})
    {:ok, table}
  end

  @impl true
  def delete(table, key) do
    :ets.delete(table, key)
    {:ok, table}
  end

  @impl true
  def list(table) do
    values = :ets.tab2list(table) |> Enum.map(fn {_k, v} -> v end)
    {:ok, values, table}
  end

  @impl true
  def entries(table) do
    entries = :ets.tab2list(table)
    {:ok, entries, table}
  end

  @impl true
  def count(table) do
    {:ok, :ets.info(table, :size), table}
  end
end
