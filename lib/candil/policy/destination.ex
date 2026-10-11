defmodule Candil.Policy.Destination do
  @moduledoc """
  One process per destination: who has the turn, and who is waiting for it.

  Este es el proceso que **sí** encola, y por eso solo existe en los dos modos
  seriales. En `:one_for_one` no se arranca nunca, y que no exista es la prueba
  —comprobable, no documentada— de que el camino caliente no pasa por aqui.

  ## Por qué un proceso por destino, y no uno global

  Porque la pregunta es de un destino y la respuesta es de un destino. Dos
  modelos distintos en la misma GPU no se estorban y no comparten cola: lo que
  se serializa es el acceso a *ese* destino. Con una cola global, un `llama-server`
  saturado frenaria tambien a la API que no tiene nada que ver, y el sintoma
  sería «Candil va lento» sin ninguna dirección.

  El nombre va en `Candil.Registry`, así que el proceso se puede encontrar por
  `whereis/1` —que es lo que usa el test para afirmar que **no** hay cola— sin
  un registro parallelo que mantener.

  ## La unidad de la cola es la petición

  Un turno se concede a un proceso que lo pidió con `GenServer.call/3`, y ese
  proceso es el que lo ejecuta. La función de trabajo **no** corre aqui dentro:
  corre en quien la llamó. Por eso un turno termina cuando la petición termina
  y no cuando el proceso de la cola decide, que es la unica forma de que
  «turno» y «petición» sean la misma cosa y no dos cuentas que se parecen.

  ## Por qué este módulo y no `Arrea.Queue`

  Porque `Arrea.Queue` es la cola de un **worker**: el worker reclama trabajo
  (`claim/2`), mira antes de coger (`peek/2`), y si no hay nada se le devuelve
  `{:error, :empty}`. Quien espera, aqui, no es un worker que pueda esperar
  pasado: es una petición que ya esta ejecutándose en el proceso de quien la
  hizo, y lo unico que puede hacer es quedarse esperando a que le toque. Eso es
  un `GenServer.reply/2` a un `from` guardado, no un bucle de `claim`.

  Y la prioridad, que es el eje de `Arrea.Queue`, aqui no significa nada: la
  pregunta de §3 del diseno es *entre los que esperan, quien sigue*, y el orden
  lo da el modo, no un numero que puso quien encolo.

  ## Lo que este proceso no sabe

  Que es un destino. No sabe si es una GPU, una cuota de euros o un puerto, y no
  pregunta: el que le llama ya lo sabe y ya ha decidido. La capacidad —si cabe,
  en que unidades— la trae `Arrea.Resource`, que es la misma forma para las tres
  cosas.
  """

  use GenServer

  require Logger

  alias Candil.Policy.Turn
  alias Candil.Telemetry

  @registry Candil.Registry
  @key :policy_destination
  @supervisor Candil.Policy.Supervisor

  @doc """
  Para la cola de un destino y la destruye si estaba.

  Existe por una sola razon: **la vida de la cola sigue a la propiedad
  `exclusive`, no al ultimo `enter/2` que la arranco.** Un destino que deja de
  ser exclusivo no puede quedarse con un proceso vivo al que el camino caliente
  no deberia llegar, y un destino que nunca fue exclusivo no tiene nada que
  parar — y eso **no es un error**, porque no habia cola.
  """
  @spec stop(atom()) :: :ok
  def stop(destination) when is_atom(destination) do
    case GenServer.whereis(via(destination)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  def stop(_destination), do: :ok

  # Un `exit` de la llamada a este proceso, y solo estos: si el proceso se
  # muere mientras alguien espera, quien espera tiene que enterarse con una
  # respuesta, no con un `exit` en la cara. Cualquier otro `exit` —el del codigo
  # de quien llama— se vuelve a lanzar, porque aqui no hay nada que tapar.
  #
  # `:killed` esta porque es como muere una cola de verdad: un `Supervisor` que
  # la para, o un `kill` de alguien. Una caida con una razon RARA —un bug— si se
  # propaga, porque un bug tiene que verse en quien la sufre y no quedarse
  # aqui como un `{:error, ...}` que nadie sabe de donde salio.
  @call_exits [:normal, :shutdown, :killed, :noproc, :noconnection]

  @typedoc "Lo que hay que saber de un destino sin pedirle nada."
  @type status :: %{
          destination: Turn.destination(),
          mode: Turn.mode(),
          holder: pid() | nil,
          waiting: non_neg_integer(),
          served: non_neg_integer()
        }

  @doc """
  El nombre registrado del destino. `nil` si no hay cola para el.
  """
  @spec whereis(Turn.destination()) :: pid() | nil
  def whereis(destination) do
    case Registry.lookup(@registry, {@key, destination}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Arranca la cola del destino, o devuelve la que ya hay.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    destination = Keyword.fetch!(opts, :destination)
    GenServer.start_link(__MODULE__, opts, name: via(destination))
  end

  @doc """
  Pide el turno. Bloquea al que llama hasta que le toque.

  `{:error, :mode_conflict}` cuando el destino ya tiene cola con **otro** modo:
  las dos variantes seriales difieren en lo que pasa al ceder el turno, asi que
  una cola no puede ser de las dos a la vez. Preferimos decirlo a elegir por el
  que llego primero.
  """
  @spec enter(Turn.destination(), Turn.mode()) ::
          {:ok, pos_integer(), reference()} | {:error, term()}
  def enter(destination, mode) do
    with {:ok, pid} <- ensure_started(destination, mode) do
      safe_call(pid, {:enter, self()})
    end
  end

  @doc """
  Cede el turno sin terminar la peticion.
  """
  @spec yield(Turn.destination(), reference()) ::
          {:ok, pos_integer(), reference()} | {:error, term()}
  def yield(destination, token) do
    safe_call(whereis(destination), {:yield, token})
  end

  @doc """
  Termina el turno.
  """
  @spec finish(Turn.destination(), reference()) :: :ok | {:error, term()}
  def finish(destination, token) do
    safe_call(whereis(destination), {:finish, token})
  end

  @doc """
  Que esta pasando en el destino, o `nil` si no hay cola.
  """
  @spec status(Turn.destination()) :: status() | nil
  def status(destination) do
    case whereis(destination) do
      nil -> nil
      pid -> safe_call(pid, :status)
    end
  end

  defp via(destination), do: {:via, Registry, {@registry, {@key, destination}}}

  defp ensure_started(destination, mode) do
    spec = {__MODULE__, destination: destination, mode: mode}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      # Dos peticiones a la vez contra un destino libre: la segunda ha llegado
      # antes de que la primera registrara el nombre. No es un error, es la
      # carrera normal de un arranque perezoso.
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_call(nil, _request), do: {:error, :policy_unavailable}

  defp safe_call(pid, request) do
    GenServer.call(pid, request, :infinity)
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in @call_exits ->
      {:error, :policy_unavailable}
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       destination: Keyword.fetch!(opts, :destination),
       # El modo se fija al arrancar y no se vuelve a cambiar. Una cola que
       # cambia de reglas bajo los pies de quien esta esperando no es una cola,
       # es dos.
       mode: Keyword.fetch!(opts, :mode),
       holder: nil,
       waiting: :queue.new(),
       served: 0
     }}
  end

  @impl true
  def handle_call({:enter, pid}, from, %{mode: mode} = state) do
    cond do
      mode != state.mode ->
        {:reply, {:error, :mode_conflict}, state}

      is_nil(state.holder) ->
        grant(state, pid, 0)

      true ->
        {:noreply, enqueue(state, pid, from)}
    end
  end

  def handle_call({:finish, token}, _from, %{holder: %{token: token}} = state) do
    {:reply, :ok, release(state)}
  end

  # Un token que no es el del titular. Llego tarde, o el que lo tenia fue
  # expulsado con `yield/1` en `:one_for_all`. Y se contesta, en vez de soltar el
  # turno de otro en silencio.
  def handle_call({:finish, _token}, _from, state) do
    {:reply, {:error, :not_holder}, state}
  end

  # `rest_for_one`: el que cede el turno vuelve AL FINAL. No se le avisa y se le
  # deja esperando: se le vuelve a conceder cuando le llegue, con un token nuevo.
  def handle_call({:yield, token}, from, %{holder: %{token: token}, mode: :rest_for_one} = state) do
    entry = %{from: from, pid: state.holder.pid, mon: state.holder.mon, asked_at: now()}

    state =
      state
      |> Map.put(:holder, nil)
      |> Map.update!(:waiting, &:queue.in(entry, &1))
      |> release()

    {:noreply, state}
  end

  # `one_for_all`: el que cede el turno lo pierde. Y no se re-encola, porque
  # Readecir el turno es justo lo que este modo dice que no pasa.
  def handle_call(
        {:yield, token},
        _from,
        %{holder: %{token: token}, mode: :one_for_all} = state
      ) do
    {:reply, {:error, :discarded}, release(state)}
  end

  def handle_call({:yield, _token}, _from, state) do
    {:reply, {:error, :not_holder}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       destination: state.destination,
       mode: state.mode,
       holder: holder_pid(state),
       waiting: :queue.len(state.waiting),
       served: state.served
     }, state}
  end

  # Si el que tenia el turno se muere, el destino se queda bloqueado para siempre
  # si nadie lo nota. Y el trabajo se ha muerto con el: no hay nada que devolver
  # al final de la cola, porque la peticion ya no existe.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %{holder: %{mon: ref}} = state) do
    Logger.warning(
      "[Candil.Policy] el destino #{inspect(state.destination)} se queda libre: " <>
        "quien tenia el turno #{inspect(pid)} ha muerto (#{inspect(reason)})"
    )

    {:noreply, state |> Map.put(:holder, nil) |> release()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_waiter(state, ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Quien estaba esperando cuando esto se apaga tiene que enterarse. Un
    # `GenServer.call` a un proceso muerto da un `exit`, y un `exit` en medio de
    # una peticion que el usuario ha hecho no es una respuesta.
    #
    # Esto NO es la red de seguridad —la que de verdad es `safe_call/2`, porque un
    # GenServer no hace `terminate/2` si lo matan con `:kill`—. Es lo que
    # corresponde cuando la cola se para CON MODALIDAD, que es lo unico que se
    # puede hacer sin Carreras.
    Enum.each(:queue.to_list(state.waiting), fn entry ->
      GenServer.reply(entry.from, {:error, :policy_unavailable})
    end)

    :ok
  end

  # ── Ayudantes ────────────────────────────────────────────────────────────────

  defp grant(state, pid, wait_native) do
    token = make_ref()
    mon = Process.monitor(pid)
    turn = state.served + 1

    Telemetry.emit_policy_turn(state.destination, state.mode, turn, wait_native, wait_native > 0)

    {:reply, {:ok, turn, token},
     %{state | holder: %{pid: pid, mon: mon, token: token}, served: turn}}
  end

  defp enqueue(state, pid, from) do
    entry = %{from: from, pid: pid, mon: Process.monitor(pid), asked_at: now()}

    %{state | waiting: :queue.in(entry, state.waiting)}
  end

  # Suelta el turno y se lo pasa al primero que hubiera. Con la cola vacia, el
  # destino queda libre y ya esta: nadie esta esperando.
  defp release(state) do
    state
    |> holder_mon()
    |> case do
      nil -> :ok
      mon -> Process.demonitor(mon, [:flush])
    end

    case :queue.out(state.waiting) do
      {{:value, entry}, waiting} ->
        turn = state.served + 1
        token = make_ref()

        Telemetry.emit_policy_turn(
          state.destination,
          state.mode,
          turn,
          now() - entry.asked_at,
          true
        )

        GenServer.reply(entry.from, {:ok, turn, token})

        %{
          state
          | waiting: waiting,
            holder: %{pid: entry.pid, mon: entry.mon, token: token},
            served: turn
        }

      {:empty, _waiting} ->
        %{state | holder: nil}
    end
  end

  defp drop_waiter(state, ref) do
    %{state | waiting: :queue.filter(&(&1.mon != ref), state.waiting)}
  end

  defp holder_pid(%{holder: nil}), do: nil
  defp holder_pid(%{holder: holder}), do: holder.pid

  defp holder_mon(%{holder: nil}), do: nil
  defp holder_mon(%{holder: holder}), do: holder.mon

  defp now, do: System.monotonic_time()
end
