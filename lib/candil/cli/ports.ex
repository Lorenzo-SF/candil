defmodule Candil.CLI.Ports do
  @moduledoc """
  Resolving which port an engine should answer on.

  Three inputs, in the order the design document fixes them (§11.2):

    1. `--port N` — an explicit number, taken as given
    2. the model's own `port`, when it is a number
    3. `EnginePool.claim_port/2` over the engine's `base_port..base_port+99`

  The preflight runs **before** any of them commit, so a start that cannot
  work never takes a port and never leaves it half-claimed.

  ## Why not "any free port"

  `claim_port/2` connects rather than asking the operating system whether the
  number is in use. A badly killed `ropero` holds a socket, every "is it free"
  check says it is free, and connecting is the only thing that tells the two
  apart.
  """

  alias Candil.EnginePool

  @doc """
  Works out the port for `model`, or explains why it cannot.
  """
  @spec resolve(Candil.Model.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def resolve(model, opts) do
    explicit = opts[:port]

    cond do
      is_integer(explicit) and explicit > 0 ->
        {:ok, explicit}

      is_integer(model.port) and model.port > 0 ->
        {:ok, model.port}

      true ->
        base = opts[:base_port] || 10_000
        EnginePool.claim_port(base, base + 99)
    end
  end

  @doc """
  The model whose alias the running instance under `port` is, if it is one of
  ours.

  Two models can be alive on different ports, so this is the reverse lookup
  that `--force` needs: who is occupying this, exactly.
  """
  @spec occupant(pos_integer()) :: {:ok, atom()} | :free | :unknown
  def occupant(port) do
    case EnginePool.list() |> Enum.find(&(&1.port == port)) do
      nil -> free_or_unknown(port)
      instance -> {:ok, instance.alias}
    end
  end

  # A port nobody registered but something is listening on. Worth saying: it is
  # the case that stops a start from silently colliding.
  defp free_or_unknown(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :unknown

      {:error, _} ->
        :free
    end
  end
end
