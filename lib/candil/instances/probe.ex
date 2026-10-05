defmodule Candil.Instances.Probe do
  @moduledoc """
  Is anything actually listening on an instance's port?

  ## Why this exists

  `status` used to print `ON` for a detached instance because the record said
  `healthy: true` — a boolean written when the instance started and never
  checked again. It answers "is the owner process alive", which is necessary
  and not sufficient.

  The user found it with a tool that is not Candil:

      [✓] analyst detached · candil status  ->  ON
      ropero status                          ->  :9999 libre

  Both were right about different questions, and only one of them was
  answering the question the column claims to answer. `STATE` in a table of
  models means "is this serving", and a process that is alive but not
  listening is exactly the thing you need to see as `DOWN` — it holds a GPU,
  it holds a port, and it answers nothing.

  A local instance gets its state from the health poller, which really does
  ask. A detached one lives in another VM, so there is nothing to ask except
  the socket.

  ## TCP, not HTTP

  A connect is enough and it is cheap. Asking for `/health` would be better,
  but the path belongs to whoever serves it, and a probe that guesses wrong
  reports a perfectly healthy llama-server as dead. A refused connection
  means the same thing in both directions and takes microseconds.
  """

  @connect_timeout 500

  @doc """
  `true` when something accepts a TCP connection on `port`.
  """
  @spec listening?(binary(), pos_integer(), timeout()) :: boolean()
  def listening?(host, port, timeout \\ @connect_timeout) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  catch
    # `host` from a malformed registry entry must not take down `status`.
    :error, _ -> false
    :exit, _ -> false
  end

  @doc """
  The state of a list of `%{host:, port:}` maps, probed in parallel.

  Parallel because `status` is interactive and a laptop with four models would
  otherwise pay four timeouts back to back on the ones that are down.
  """
  @spec states([map()], keyword()) :: %{optional(pos_integer()) => binary()}
  def states(instances, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @connect_timeout)

    instances
    |> Task.async_stream(
      fn instance -> {instance.port, listening?(instance.host, instance.port, timeout)} end,
      max_concurrency: 8,
      timeout: timeout * 2,
      on_timeout: :kill_task
    )
    |> Enum.zip(instances)
    |> Map.new(fn {res, instance} ->
      # La tarea devuelve `{port, listening?}`, no un booleano pelado:
      # `match?({:ok, true}, ...)` no coincide nunca con `{:ok, {port, true}}`
      # y salia DOWN para todo. Un test que solo mire que el mapa trae una
      # clave por puerto no lo ve — un valor equivocado tambien es un valor.
      {instance.port, if(match?({:ok, {_port, true}}, res), do: "ON", else: "DOWN")}
    end)
  end
end
