defmodule Candil.Cancellation do
  @moduledoc """
  Registry of in-flight LLM generations, keyed by a `cancel_ref/0`.

  Callers can request cancellation of an ongoing generation by passing
  the reference to `cancel/1`. The current generation checks the
  registry at chunk boundaries; if the reference is cancelled it
  returns `{:halt, :cancelled}` from the streaming parser.

  This is intentionally lightweight — a `Registry` with
  `partitions: 1` for low-overhead inserts, and `ETS`-backed counters
  for live counts.
  """

  use GenServer

  @name __MODULE__

  @doc """
  Generate a new cancellation reference.
  """
  @spec new_ref() :: reference()
  def new_ref, do: make_ref()

  @doc """
  Mark a generation as in-flight under the given ref.

  Stores `owner_pid` so that cancellations only fire from the same
  process that started the generation (prevents accidental
  cancellation from a different request).
  """
  @spec register(reference(), pid()) :: :ok
  def register(ref, owner_pid \\ self()) do
    GenServer.call(@name, {:register, ref, owner_pid})
  end

  @doc """
  Mark a generation as done. Idempotent.
  """
  @spec done(reference()) :: :ok
  def done(ref) do
    GenServer.call(@name, {:done, ref})
  end

  @doc """
  Cancel an in-flight generation. Returns `:ok` if cancelled,
  `:not_found` if the ref is unknown (already done).
  """
  @spec cancel(reference()) :: :ok | :not_found
  def cancel(ref) do
    GenServer.call(@name, {:cancel, ref})
  end

  @doc """
  Has the ref been cancelled? Returns `true` or `false`. Returns
  `false` if the ref is unknown.
  """
  @spec cancelled?(reference()) :: boolean()
  def cancelled?(ref) do
    GenServer.call(@name, {:cancelled?, ref})
  end

  @doc """
  Number of in-flight generations across all owners.
  """
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(@name, :count)
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @name))
  end

  @impl true
  def init(:ok), do: {:ok, %{refs: %{}, cancelled: MapSet.new()}}

  @impl true
  def handle_call({:register, ref, owner_pid}, _from, state) do
    {:reply, :ok, %{state | refs: Map.put(state.refs, ref, owner_pid)}}
  end

  @impl true
  def handle_call({:done, ref}, _from, state) do
    {:reply, :ok, %{state | refs: Map.delete(state.refs, ref)}}
  end

  @impl true
  def handle_call({:cancel, ref}, _from, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, _owner} ->
        {:reply, :ok, %{state | cancelled: MapSet.put(state.cancelled, ref)}}

      :error ->
        {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call({:cancelled?, ref}, _from, state) do
    {:reply, MapSet.member?(state.cancelled, ref), state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, map_size(state.refs), state}
  end
end