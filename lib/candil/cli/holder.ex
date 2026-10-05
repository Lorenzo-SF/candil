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

  alias Arrea.LongRunning
  alias Candil.{Engine, Engine.Server, Instances, Store}
  require Logger

  # 4 minutos. Un 30B MoE sobre disco NVMe tarda del orden de medio minuto en
  # empezar a contestar, y el presupuesto es para el caso raro, no para el
  # normal: si tarda mas que esto, algo va mal y el titular debe decirlo.
  @health_budget :timer.minutes(4)

  # Cada vuelta del bucle consulta con este timeout, no con el de 5s por
  # defecto de `Engine.healthy?/1`. Con 5s por vuelta, un engine que no
  # responde se come el presupuesto entero en dos iteraciones sin comprobar
  # nada nuevo, que es un timeout que no es un timeout: es un cuelgue con
  # contador.
  @health_call_timeout 500

  @doc """
  Starts the engine for `alias` on `port`, claims it, and blocks forever.

  The claim only happens when the model actually answers. That is the whole
  point, and it is the thing the old code got wrong in both directions: it
  claimed before anything owned the port, and then it claimed a process that
  had not come up.

  Returns `{:error, reason}` without claiming anything if the engine never
  becomes healthy. It does not halt: see the note by the `{:error, reason}`
  clause.
  """
  @spec start(binary(), pos_integer(), keyword()) ::
          :ok | {:error, :no_such_model | :timeout | :engine_died | {:engine_refused, term()}}
  def start(alias_name, port, opts \\ []) when is_binary(alias_name) and is_integer(port) do
    budget = Keyword.get(opts, :health_budget, @health_budget)
    cpu? = Keyword.get(opts, :cpu, false)

    with {:ok, alias_atom} <- safe_atom(alias_name),
         {:ok, model} <- fetch(alias_atom) do
      start_model(model, alias_name, port, budget, cpu?)
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

  defp start_model(model, alias_name, port, budget, cpu?) do
    # El engine del catalogo, no uno hecho a pelo: `%Candil.Engine{alias: ...}`
    # no tiene binary ni puerto y arrancaria contra el 8080 sin binario.
    case Engine.for_model(model, port, cpu?) do
      {:ok, engine} ->
        # `Engine.start/2` y no `EnginePool.put/5`, igual que en la ruta
        # normal: el pool no arranca nada, solo se apunta. Y `Engine.start/2`
        # se niega con un motivo si el binario no esta, en vez de devolver `:ok`
        # sin haber hecho nada.
        case Engine.start(engine, model) do
          {:ok, _pid} -> claim_when_healthy(model, engine, alias_name, port, budget)
          {:error, reason} -> {:error, {:engine_refused, reason}}
        end

      {:error, :not_found} ->
        IO.puts(:stderr, "holder: el modelo #{alias_name} no tiene engine en la configuracion")
        {:error, :no_such_model}
    end
  end

  defp claim_when_healthy(model, engine, alias_name, port, budget) do
    # `EnginePool.put` contesta en cuanto el PROCESO arranca, no en cuanto el
    # modelo responde: la espera de salud la hace Arrea despues y en segundo
    # plano. Reclamar aqui era escribir un ownership sobre un motor que
    # todavia no existia — el mismo fallo un nivel mas abajo, con el mismo
    # reclamo: el titular se quedaba vivo, `status` ponia detached, y luego
    # DOWN con 47 MB de GPU y nada escuchando.
    #
    # El registro significa "esto esta sirviendo". Si no llega, no se escribe.
    case await_health(model.alias, budget) do
      :ok ->
        :ok =
          Instances.put(
            {alias_name, port},
            Instances.build(
              alias_name,
              port,
              to_string(model.engine),
              Instances.os_pid(),
              true,
              engine.host
            )
          )

        Logger.info("holder: #{alias_name} responde en :#{port} · pid #{Instances.os_pid()}")
        block(Server.id_for(model, engine))

      {:error, reason} ->
        # Devuelve, NO detiene. Un `System.halt/1` aqui se lleva por delante
        # tambien a un host que ha incrustado Candil como libreria, y a la
        # propia suite de tests: fue exactamente lo que paso, la suite murio
        # sin imprimir resumen y con exit 0. Detener es trabajo del limite del
        # escript, `Candil.CLI.Escript.hold/2`, que es el unico sitio autorizado
        # a llamar a halt.
        {:error, reason}
    end
  end

  @doc """
  Turns a failure reason into the sentence a person needs.
  """
  @spec explain(atom()) :: binary()
  def explain({:engine_refused, reason}),
    do: "el engine se ha negado a arrancar: #{reason}"

  def explain(:no_such_model), do: "no hay ningun modelo con ese alias"

  def explain(:timeout),
    do: "el proceso arranco pero el modelo no ha contestado en el tiempo previsto"

  def explain({:engine_died, reason}),
    do: "el proceso del engine se ha caido antes de responder — #{reason}"

  def explain(:engine_died),
    do: "el proceso del engine se ha caido antes de responder"

  # Un modelo de 17 GB tarda en cargar; uno muerto no tarda. Se comprueba el
  # pool cada medio segundo mientras queda presupuesto, y en cuanto el GenServer
  # desaparece se deja de esperar: `Engine.healthy?/1` ya dira false, pero
  # esperar el presupuesto entero a algo que no va a venir solo hace tarde.
  defp await_health(model_alias, budget) do
    cond do
      Engine.healthy?(model_alias, @health_call_timeout) ->
        :ok

      budget <= 0 ->
        {:error, :timeout}

      engine_alive?(model_alias) ->
        Process.sleep(500)
        await_health(model_alias, budget - 500)

      true ->
        # El motivo de la muerte es lo unico que explica el fallo, asi que se
        # vigila al proceso en vez de conformarse con "se ha caido".
        {:error, {:engine_died, await_death(model_alias)}}
    end
  end

  # Una vuelta de mas al GenServer del engine, esperando su DOWN. Es el unico
  # sitio donde el motivo real de la muerte esta disponible.
  defp await_death(model_alias) do
    case Registry.lookup(Engine.registry(), model_alias) do
      [{pid, _}] ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} -> inspect(reason)
        after
          200 -> "(sin razon: el proceso ya no estaba)"
        end

      [] ->
        "(ya no estaba en el registro)"
    end
  end

  defp engine_alive?(model_alias) do
    case Registry.lookup(Engine.registry(), model_alias) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  @doc """
  Never returns. Stops cleanly on SIGTERM/SIGINT so `stop` and `candil stop`
  can take the engine down with the owner instead of orphaning it.
  """
  @spec block(term()) :: no_return()
  def block(id) do
    # Atrapar salidas es para poder ORDENAR la muerte del engine antes de la
    # propia, no solo para enterarse de ella.
    Process.flag(:trap_exit, true)
    hold(id)
  end

  # El titular es el dueño del proceso, y la regla C19 es que matar al dueño
  # se lleva el engine. Sin apagar el engine explícitamente, al morir el VM el
  # `llama-server` —que es un proceso del SISTEMA OPERATIVO, no de Erlang— se
  # queda huerfano y reparteado a init: vivo, con la GPU cogida, y sin nadie a
  # quien preguntarle. Se vio justo asi, con `ropero` diciendo ON y `candil
  # status` diciendo que no habia nada.
  #
  # Se apaga y luego se sale con codigo 0: si el engine se cae por su cuenta, el
  # titular no ha fallado — ha hecho su trabajo, y el log ya lo dice.
  # Un `receive` sin `after` no termina nunca, y dialyzer lo ve como una
  # funcion que solo acaba lanzando. Se declara que devuelve lo que sea, que
  # es verdad: de este `receive` no se sale con un valor.
  @spec hold(term()) :: no_return()
  defp hold(id) do
    receive do
      {:EXIT, _pid, _reason} ->
        LongRunning.stop(id)
        exit(0)

      :stop ->
        LongRunning.stop(id)
        exit(0)
    end
  end
end
