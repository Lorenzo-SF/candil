defmodule Candil.CLI.Holder do
  @moduledoc """
  The process that actually owns a `--detach`ed instance.

  ## What was broken

  `candil run <model> --detach` used to record the instance with
  `Instances.os_pid()` — the pid of the escript that was about to exit — and
  then print `detached (owner pid 595922)`. Verified on a real run:

      [✓] probe detached (owner pid 2733) · log: .../probe-9999.log
      /proc/2733          -> dead
      ps                 -> no engine process at all
      instances.json     -> {"pid":2733, "healthy":true}
      that log file      -> never created

  Three lies in one line: a process that does not exist, a log that was never
  opened, and a healthy record for a dead pid. The engine was started as a
  child of the launching VM, so it left with it, and `read/0` pruned the record
  the moment `alive?/1` asked the operating system about pid 2733.

  So `--detach` was not "detach". It was "start, announce, and die".

  ## What it is now

  A second Candil process. The launcher spawns one, it starts the engine, it
  records **its own** pid as the owner, and it blocks. `Instances.alive?/1`
  then tells the truth about a process that is genuinely alive, and `stop` and
  `status` work against it without a single change: they were always asking
  the OS about the recorded pid, and now the recorded pid is the real one.

  ## It dies with the session, on purpose

  The holder is a child of the shell in the same way the engine was, detached
  from the terminal with `setsid` so that closing a pane does not take it
  out. It is not a service, and it should not become one: a model that
  outlives your session is a model holding your VRAM after you went to bed.
  Killing the holder's process group takes the engine with it, which is the
  C19 rule and the reason the owner is recorded at all.
  """

  alias Candil.{EnginePool, Instances, Store}
  require Logger

  @doc """
  Starts the engine for `alias` on `port`, claims it, and blocks forever.

  Returns `:ok` only if the claim is in the registry when this function
  returns — which is the whole point, and the thing the old code got wrong by
  order: it wrote the record before anything was there to own it.
  """
  @spec start(binary(), pos_integer()) :: :ok | {:error, :no_such_model}
  def start(alias_name, port) when is_binary(alias_name) and is_integer(port) do
    with {:ok, alias_atom} <- safe_atom(alias_name),
         {:ok, model} <- fetch(alias_atom) do
      start_model(model, alias_name, port)
    end
  end

  # El alias viene de una linea de comandos, y `String.to_existing_atom` lanza
  # para un nombre que este VM no ha visto nunca. Un atomo de lo que el usuario
  # teclee se crea sin limite en la tabla de atoms, y eso no es un lookup: es
  # una denegacion de servicio de la que uno mismo se puede_curar. Sin
  # `creating: true` no se crea nada, y un nombre desconocido sale como error.
  # Los dos fallos posibles —alias desconocido o atomo que no existe— son el
  # mismo fallo para quien lee: no hay ese modelo. Dejarlos como dos motivos
  # distintos inventa una distincion que nadie puede aprovechar.
  defp fetch(alias_atom) do
    case Store.get_model(alias_atom) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> {:error, :no_such_model}
    end
  end

  defp safe_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :no_such_model}
  end

  defp start_model(model, alias_name, port) do
    engine = %Candil.Engine{alias: model.engine}

    :ok = EnginePool.put(model.alias, port, nil, model, engine)

    instance =
      Instances.build(
        alias_name,
        port,
        to_string(model.engine),
        Instances.os_pid(),
        true
      )

    :ok = Instances.put({alias_name, port}, instance)

    Logger.info("holder: #{alias_name} en :#{port}, owner pid #{Instances.os_pid()}")
    block()
  end

  @doc """
  Never returns. Stops cleanly on SIGTERM/SIGINT so `stop` and `candil stop`
  can take the engine down with the owner instead of orphaning it.
  """
  @spec block() :: no_return()
  def block do
    # Trapping exits means a supervisor shutdown reaches here as a message
    # rather than killing the VM outright, which is what lets the engine's own
    # shutdown run. The escript's own SIGTERM handling is the outer backstop.
    Process.flag(:trap_exit, true)
    hold()
  end

  defp hold do
    receive do
      {:EXIT, _pid, reason} -> exit(reason)
      _ -> hold()
    end
  end
end
