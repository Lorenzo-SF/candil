defmodule Candil.Storage.Store do
  @moduledoc """
  La fachada del almacenamiento: elige el adaptador y delega.

  Un proceso en el árbol que posee el adaptador y su estado. Quien llama no
  sabe qué adaptador hay debajo; solo sabe que puede guardar y leer. Cambiar
  de ETS a Postgres es cambiar una línea en la configuración, no el código que
  lo usa.
  """

  use GenServer

  @default_adapter Candil.Storage.ETS

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    adapter = Keyword.get(opts, :adapter, @default_adapter)
    {:ok, state} = adapter.init(opts)
    GenServer.start_link(__MODULE__, {adapter, state}, name: __MODULE__)
  end

  @doc "Lee el valor de `key`."
  @spec get(term()) :: {:ok, term()} | {:error, :not_found}
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc "Guarda `value` bajo `key`."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc "Borra `key`."
  @spec delete(term()) :: :ok
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @doc "Lista todos los valores."
  @spec list() :: [term()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Lista todos los pares {clave, valor}."
  @spec entries() :: [{term(), term()}]
  def entries do
    GenServer.call(__MODULE__, :entries)
  end

  @doc "El nombre de la tabla subyacente (para el adaptador ETS)."
  @spec table() :: atom() | nil
  def table do
    GenServer.call(__MODULE__, :table)
  end

  @doc "Cuenta los valores."
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @doc "El adaptador activo."
  @spec adapter() :: module()
  def adapter do
    GenServer.call(__MODULE__, :adapter)
  end

  @impl GenServer
  def init({adapter, state}) do
    {:ok, {adapter, state}}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, {adapter, state}) do
    {:reply, adapter.get(state, key), {adapter, state}}
  end

  def handle_call({:put, key, value}, _from, {adapter, state}) do
    {:ok, new_state} = adapter.put(state, key, value)
    {:reply, :ok, {adapter, new_state}}
  end

  def handle_call({:delete, key}, _from, {adapter, state}) do
    {:ok, new_state} = adapter.delete(state, key)
    {:reply, :ok, {adapter, new_state}}
  end

  def handle_call(:list, _from, {adapter, state}) do
    {:ok, values, new_state} = adapter.list(state)
    {:reply, values, {adapter, new_state}}
  end

  def handle_call(:entries, _from, {adapter, state}) do
    {:ok, entries, new_state} = adapter.entries(state)
    {:reply, entries, {adapter, new_state}}
  end

  def handle_call(:table, _from, {adapter, state}) do
    table = if is_atom(state), do: state, else: nil
    {:reply, table, {adapter, state}}
  end

  def handle_call(:count, _from, {adapter, state}) do
    {:ok, n, new_state} = adapter.count(state)
    {:reply, n, {adapter, new_state}}
  end

  def handle_call(:adapter, _from, {adapter, state}) do
    {:reply, adapter, {adapter, state}}
  end
end
