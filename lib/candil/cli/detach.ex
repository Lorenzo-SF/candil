defmodule Candil.CLI.Detach do
  @moduledoc """
  Spawns the holder process for `--detach` and waits until it really exists.

  ## The rule this module exists to enforce

  **Do not announce it before it is there.**

  The old code wrote the instance record, printed `detached (owner pid N)`,
  and exited. The pid belonged to the process doing the printing. By the time
  any second `candil` looked, the OS had forgotten it, `alive?/1` said no, and
  the record was pruned — so `status` reported nothing and `stop` could not
  reach an engine that might or might not still be running.

  Here the launcher polls the registry until the claim shows up. Success is
  something that happened, not something that was printed.
  """

  alias Candil.Instances

  @default_timeout :timer.seconds(30)
  @poll_interval 100

  @doc """
  Spawns the holder and waits for it to claim `{alias, port}`.

  Returns `:ok` with the owner's pid, or `{:error, reason}`.
  """
  @spec spawn(binary(), pos_integer(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def spawn(alias_name, port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    log = Keyword.get(opts, :log) || default_log(alias_name, port)

    case script_path() do
      nil ->
        {:error, :no_script_path}

      script ->
        command(script, alias_name, port, log)
        await_claim(alias_name, port, timeout, log)
    end
  end

  # `setsid` para un grupo de procesos propio, y la redireccion entera a un
  # descriptor que no es un terminal. Sin esto el holder muere con el
  # escript que lo lanza, que es exactamente el bug.
  #
  # Sin `nohup`, ademas: SIGHUP llega al grupo cuando se cierra el terminal, y
  # el hold esta pensado para morir CON la sesion, no antes.
  defp command(script, alias_name, port, log) do
    :ok = File.mkdir_p(Path.dirname(log))

    shell =
      "setsid '#{script}' __hold '#{alias_name}' #{port} " <>
        ">>'#{log}' 2>&1 < /dev/null &"

    # `setsid` no esta en macOS por defecto; ahi `nohup` hace el papel.
    runner = if System.find_executable("setsid"), do: "setsid", else: "nohup"
    :ok = File.mkdir_p(Path.dirname(log))
    {_out, 0} = System.cmd("sh", ["-c", String.replace_prefix(shell, "setsid", runner)])

    :ok
  end

  defp await_claim(alias_name, port, timeout, log) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(alias_name, port, deadline, log)
  end

  defp poll(alias_name, port, deadline, log) do
    case claimed(alias_name, port) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_interval)
          poll(alias_name, port, deadline, log)
        else
          # Un mensaje de "detached" aqui seria mentira, y el log es lo unico
          # que puede decir por que.
          {:error, {:holder_no_arrived, log}}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp claimed(alias_name, port) do
    Enum.find_value(Instances.all(), fn %{model: m, port: p, pid: pid} = instance ->
      if to_string(m) == alias_name and p == port and Instances.alive?(instance), do: pid
    end)
  end

  defp default_log(alias_name, port) do
    Path.join([
      Instances.data_dir(),
      "logs",
      "#{alias_name}-#{port}.log"
    ])
  end

  @doc """
  The path of the running escript, or `nil` outside one.
  """
  @spec script_path() :: binary() | nil
  def script_path do
    if function_exported?(:escript, :script_name, 0) do
      case :escript.script_name() do
        [] -> nil
        name -> List.to_string(name)
      end
    end
  end
end
