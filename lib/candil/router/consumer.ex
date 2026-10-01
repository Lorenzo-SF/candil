defmodule Candil.Router.Consumer do
  @moduledoc """
  Per-consumer settings: which models it may use, and which one wins outright.

  Candidates come from three places, most specific first:

    1. a pin, if `pin/2` was called
    2. `[consumer.X] models` in the config file
    3. the consumer's `model_default`

  The important property is that the list is a *subset* of what exists, not
  "whatever `head/1` returns". A consumer with no models configured gets an
  error, not a model it was never meant to talk to — least of all one whose
  only usage is `:embeddings`.
  """

  use GenServer

  @pinned_table :candil_router_pins

  @doc false
  @spec pinned_table() :: atom()
  def pinned_table, do: @pinned_table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pins a model for a consumer.
  """
  @spec pin(atom(), atom()) :: :ok
  def pin(consumer, model_alias) do
    :ets.insert(@pinned_table, {consumer, model_alias})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Removes a pin.
  """
  @spec unpin(atom()) :: :ok
  def unpin(consumer) do
    :ets.delete(@pinned_table, consumer)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The pinned model, if any.
  """
  @spec pinned(atom()) :: {:ok, atom()} | :error
  def pinned(consumer) do
    case :ets.lookup(@pinned_table, consumer) do
      [{_consumer, model_alias}] -> {:ok, model_alias}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  The model aliases this consumer may use, most preferred first.
  """
  @spec candidates(atom()) :: [atom()]
  def candidates(consumer) do
    case pinned(consumer) do
      {:ok, model_alias} ->
        [model_alias]

      :error ->
        configured = configured_models(consumer)

        case configured do
          [] -> default_candidate(consumer)
          list -> list
        end
    end
  end

  defp configured_models(consumer) do
    consumer
    |> settings()
    |> Map.get(:models, [])
    |> List.wrap()
  end

  defp default_candidate(consumer) do
    case settings(consumer)[:model_default] do
      nil -> []
      alias -> [alias]
    end
  end

  # The config file is not parsed until phase 1 wires it up, so this reads
  # from the application environment that config.exs still uses. It keeps the
  # Router's contract testable now without pretending the TOML is wired.
  defp settings(consumer) do
    :candil
    |> Application.get_env(Candil.Router, [])
    |> Keyword.get(:consumers, %{})
    |> Map.get(consumer, %{})
  end

  @doc false
  @impl GenServer
  def init(_opts) do
    :ets.new(@pinned_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
