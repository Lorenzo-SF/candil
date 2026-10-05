defmodule Candil.Instances.Reaper do
  @moduledoc """
  Sweeps dead entries out of `instances.json`.

  ## Why this is needed at all

  `Candil.Instances.read/0` already filters dead entries — it is the honest
  answer to "what is running". But it filters **in memory**: nothing ever
  writes the pruned list back, so a record that dies stays in the file
  forever. Every run, every crash, every `stop` that did not get to run
  leaves a corpse.

  That is not a slow leak, it is a small lie. A second process reading the
  file sees `{"pid": 1234, "healthy": true}` for a pid that exited an hour
  ago, and a file that only ever grows.

  ## What it does NOT do

  It does not kill anything. A dead owner means the OS already took the
  engine with it — that is the whole C19 rule, and this module is the second
  half of the sentence: making sure the leftover does not keep pretending.

  ## A detached instance is not an orphan

  The sweep uses `Instances.alive?/1`, which asks the operating system about
  the recorded owner pid. An instance whose owner is still running is left
  completely alone, however long it has been going, however big the model.
  Only entries the OS has already forgotten are touched.
  """

  use GenServer
  alias Candil.Instances
  require Logger

  @default_interval :timer.minutes(5)

  @doc """
  Starts the reaper. Returns the pid.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Removes the entries whose owner is gone, and returns how many.

  Synchronous, so a test does not have to wait for a tick, and so the CLI can
  call it once on a fresh VM before it answers anything about what is running.
  """
  @spec prune() :: non_neg_integer()
  def prune do
    raw = Instances.all()
    kept = Enum.filter(raw, &Instances.alive?/1)
    removed = length(raw) - length(kept)

    if removed > 0, do: Instances.write(kept)
    removed
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # `> 0` y no `if removed = ...`: en Elixir 0 es verdad, asi que un truthiness
    # aqui no falla nunca, solo escribe un log de mas cada cinco minutos.
    removed = prune()

    if removed > 0 do
      Logger.debug("instances.reaper: quitadas #{removed} instancia(s) muertas")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
