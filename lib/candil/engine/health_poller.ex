defmodule Candil.Engine.HealthPoller do
  @moduledoc """
  Shared health-polling logic for engine GenServers.

  Both `Candil.Engine.Server` and `Candil.Engine.Server.External` poll
  `<base_url>/health` every 5 seconds. This module provides the common
  `probe_health/1` function and macros/clauses for the repeated
  `handle_call(:health, ...)`, `handle_call(:base_url, ...)` and
  `handle_info(:poll_health, ...)` patterns.
  """

  alias Candil.HTTP

  @health_poll_ms 5_000

  @doc """
  Probe `base_url/health` and return `true` if reachable (HTTP 200).
  """
  @spec probe_health(binary()) :: boolean()
  def probe_health(base_url) do
    case HTTP.get("#{base_url}/health", [], timeout_ms: 1_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Returns the poll interval in milliseconds.
  """
  @spec poll_interval :: pos_integer()
  def poll_interval, do: @health_poll_ms

  @doc """
  Returns the initial state map with `healthy: false`.
  """
  @spec initial_state(keyword()) :: map()
  def initial_state(extra \\ []) do
    Map.merge(%{healthy: false}, Map.new(extra))
  end

  @doc """
  Implements `c:GenServer.handle_call/3` for `:health` and `:base_url`.

  Use from your GenServer via:
  ```elixir
  def handle_call(:health, _from, state), do: HealthPoller.handle_health_call(state)
  def handle_call(:base_url, _from, state), do: HealthPoller.handle_base_url_call(state, state.base_url)
  ```
  """
  def handle_health_call(state) do
    {:reply, if(state.healthy, do: :ok, else: :not_ready), state}
  end

  def handle_base_url_call(state, base_url) do
    {:reply, base_url, state}
  end

  @doc """
  Implements the `:poll_health` timer message.

  Call from your GenServer's `handle_info/2`:
  ```elixir
  def handle_info(:poll_health, state), do: HealthPoller.handle_poll_health(state)
  ```
  """
  def handle_poll_health(state) do
    healthy = probe_health(state.base_url)
    Process.send_after(self(), :poll_health, @health_poll_ms)
    {:noreply, %{state | healthy: healthy}}
  end
end
