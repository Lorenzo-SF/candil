defmodule Candil.Engine.Resource.Placement do
  @moduledoc """
  El cerrojo de las **colocaciones**: decidir dónde va un modelo y reservar su
  VRAM son una sola operación, no dos.

  ## Por qué hace falta

  Dos `start_placed/2` concurrentes pueden medir **la misma** memoria libre
  (el `sync_foreign` de uno todavía no ve lo que el otro acaba de reservar) y
  decidir los dos que su modelo cabe. El primero reserva; el segundo recibe un
  error de acquire —que no explica nada— y su modelo no arranca, cuando en
  realidad lo que había era sitio de sobra y una carrera.

  Con el cerrojo, el segundo **espera** y vuelve a decidir con la memoria ya
  cambiada: si ahora no cabe, lo dice (`no_room`), y si cabe, reserva.

  ## Por qué un semáforo y no un mutex con la función dentro

  El trabajo (arrancar un motor) tiene que seguir siendo **del proceso que lo
  pide**: el motor nace como hijo suyo, y si el cerrojo ejecutara la función,
  el motor sería hijo del cerrojo. El semáforo da el turno: el que pide entra
  cuando le toca y **sale** al terminar.

  ## Por qué no `:global.trans/3`

  En OTP 28 la API de cerrojos de `:global` (`set_lock/2`, `get_lock/2`,
  `del_lock/1`) **ya no existe**, y `trans/3` se quedó sin hacer nada: dos
  llamadas concurrentes se ejecutan en paralelo. Medido el 2026-10-22:
  `trans/3` con dos tareas de un segundo tardó 1,0 s en vez de 2,0 s.
  """

  use GenServer

  @type state :: %{holder: pid() | nil, waiting: :queue.queue()}

  @doc """
  Arranca el cerrojo. Va en la supervision de la aplicacion: si el cerrojo se
  cae, las colocaciones se Paran (que es mejor que una sin cerrojo).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Toma el cerrojo, ejecuta `fun` y lo suelta.

  Lo que devuelve `fun` es lo que devuelve esta función. Si el cerrojo no se
  puede tomar en el plazo, se dice (`{:error, :placement_busy}`) en vez de
  dejar caer al llamante con una excepcion.
  """
  @spec with_lock((-> result), timeout()) :: result | {:error, :placement_busy}
        when result: term()
  def with_lock(fun, timeout \\ 60_000) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:acquire, self()}, timeout)

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, {:release, self()})
    end
  catch
    :exit, _reason -> {:error, :placement_busy}
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{holder: nil, waiting: :queue.new()}}

  @impl GenServer
  def handle_call({:acquire, pid}, _from, %{holder: nil} = state) do
    {:reply, :ok, grant(state, pid)}
  end

  def handle_call({:acquire, pid}, from, state) do
    # El turno espera: no se contesta hasta que el que lo tiene lo suelta.
    {:noreply, %{state | waiting: :queue.in({pid, from}, state.waiting)}}
  end

  @impl GenServer
  def handle_cast({:release, pid}, %{holder: pid} = state) do
    {:noreply, pass_the_baton(state)}
  end

  def handle_cast({:release, _other}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{holder: pid} = state) do
    # El que tenia el cerrojo se murio sin soltarlo (un `kill`): el turno pasa
    # al siguiente, que si no se quedaria esperando para siempre.
    {:noreply, pass_the_baton(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp grant(state, pid) do
    # Se vigila al que tiene el turno: si se muere sin soltar, el cerrojo no
    # se queda colgado.
    Process.monitor(pid)
    %{state | holder: pid}
  end

  defp pass_the_baton(state) do
    case :queue.out(state.waiting) do
      {{:value, {next_pid, from}}, rest} ->
        GenServer.reply(from, :ok)
        grant(%{state | waiting: rest}, next_pid)

      {:empty, _rest} ->
        %{state | holder: nil}
    end
  end
end
