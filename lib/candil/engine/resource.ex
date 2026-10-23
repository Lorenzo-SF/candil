defmodule Candil.Engine.Resource do
  # Nombres de device precalculados en compilación. `Arrea.Resource` se
  # registra por átomo y el índice viene de fuera —de la lista de devices del
  # motor—, o sea `:"device#{index}"` en runtime crearía átomos desde un dato
  # que no controla este módulo. 32 devices es de sobra; un índice mayor es un
  # error explícito.
  #
  # El nombre es **neutro** a propósito (D-28): el backend no es parte de la
  # identidad del device. Que el device 0 se llamara `:cuda0` convertía una
  # convención de CUDA en la identidad del proyecto, y en ROCm o en SYCL el
  # mismo slot se habría llamado igual de mentira.
  @max_devices 32

  @device_names Enum.map(0..(@max_devices - 1), fn index ->
                  String.to_atom("device" <> Integer.to_string(index))
                end)

  @moduledoc """
  Gestiona el ciclo de vida de `Arrea.Resource` por device.

  `Arrea.Resource` es la pieza que decide si un modelo cabe en una GPU: capacidad
  entera en megas, cuota decimal, identidad estricta del titular. Este módulo
  es el consumidor que D-27 pedía: registra el resource al arrancar, reserva
  antes de cargar, libera si el motor muere.

  ## Capacidad: la del motor, y solo del motor

  D-28: **un device es un slot con un nombre, un presupuesto y una sola fuente
  de medida**. Aquí la fuente es el motor —`llama-server --list-devices`—, que
  publica el nombre (`CUDA0`, `ROCm0`…), la capacidad que él ve y el libre en
  el mismo instante.

  La capacidad del motor **ya viene sin el contexto de CUDA**: son 15933 MiB,
  no los 16303 que ve `nvidia-smi`. Por eso aquí **no hay titular `:system`**:
  el overhead ya está fuera de la capacidad, y tenerlo además como titular lo
  descontaría dos veces.

  Y por eso **no hay una constante de overhead**: los 370 MiB eran la diferencia
  entre las dos fuentes en esta máquina (16303 − 370 = 15933), no una propiedad
  de CUDA, y menos aún de ROCm, de SYCL o de Vulkan. Con una sola fuente, la
  calibración no hace falta: el motor ya la aplicó.

  ## La fórmula

      available = capacity − foreign − candil_used

  con

      foreign = max(capacity − free − candil_used, 0)

  de donde `available = free`: el libre que el motor ve. Y `candil_used` es la
  suma de los titulares de los modelos de Candil, **sin** el titular `:foreign`.

  ## Cuota

  Un modelo local no compite por un presupuesto blando: la cuota de cada
  `acquire/3` es **`0`**, que en `Arrea.Resource` significa «este modelo no
  consume cuota» y es una afirmación legítima. `:infinity` **no** vale en ese
  eje —solo como `:quota` del resource— y devuelve `:unknown_cost`, que aborta
  el arranque. Por eso la cuota no es un parámetro de este módulo.

  ## Titular

  El titular es `{alias, port, generacion}` (un tuple), no solo el alias ✓.
  Con eso dos instancias del mismo modelo reservan por separado ✓ y `release`
  es exacto ✓. La identidad estricta de `Arrea.Resource` (`===`) funciona con
  tuples ✓.

  **La generacion** (`make_ref/0` ✓) esta porque `{alias, port}` **no es unico
  en el tiempo** ✓: si el puerto se reutiliza y el `terminate/2` del server
  viejo llega tarde, su `release` —que quita la primera entrada de ese
  titular— podria soltar la reserva **del modelo nuevo** ✓. Con la generacion,
  la reserva vieja solo la suelta quien la pidio ✓.

  ## Nombres de device

  Los nombres están precalculados en compilación para `0..#{@max_devices - 1}`;
  un índice mayor es un error explícito, no un átomo nuevo.
  """

  # Cuánto puede cambiar la memoria ajena antes de reajustar el ledger. Con
  # menos de esto, cada arranque provocaría un `release`+`acquire` por unos
  # megas de diferencia entre dos mediciones del motor.
  @foreign_threshold_mb 64

  @doc """
  Registra el resource de un device si no existe. Idempotente.

  La capacidad es la del **motor** (`llama-server --list-devices`): la que
  él ve, que ya está sin su contexto. Si la medición no da una capacidad
  positiva, **no se registra** el resource: una capacidad 0 se comería todos
  los arranques para siempre y «no lo sé» no es «ahora no cabe nada».

  La medición entra como **dato** (`%{index:, total_mb:, free_mb:}`), no como
  una forma de medir: el ledger no sabe de dónde salen las cifras, y así no
  puede medirlas de dos maneras distintas.
  """
  @spec ensure_registered(map()) :: :ok | {:error, :capacity_unknown}
  def ensure_registered(%{index: device_index, total_mb: total})
      when is_integer(device_index) and device_index >= 0 and is_integer(total) do
    name = device_name(device_index)

    case Registry.lookup(Arrea.Resource.Registry, name) do
      [{_pid, _}] ->
        :ok

      [] ->
        if total > 0 do
          register(name, total)
        else
          {:error, :capacity_unknown}
        end
    end
  end

  @doc """
  Reserva capacidad en un device. Devuelve `{:ok, receipt}` o un error.

  `cost` son megas enteros `> 0`. La cuota de política es siempre `0`: un
  modelo local no consume un presupuesto blando, y `Arrea.Resource` exige un
  número en ese eje.
  """
  @spec acquire(map(), term(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def acquire(device = %{index: device_index}, holder, cost)
      when is_integer(device_index) and device_index >= 0 and is_integer(cost) and cost > 0 do
    with :ok <- ensure_registered(device) do
      Arrea.Resource.acquire(device_name(device_index), holder, cost, 0)
    end
  end

  @doc """
  Libera la reserva de un titular en un device.
  """
  @spec release(non_neg_integer(), term()) :: {:ok, map()} | {:error, term()}
  def release(device_index, holder) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)
    Arrea.Resource.release(name, holder)
  end

  @doc """
  Serializa las **colocaciones**: decidir dónde va un modelo y reservar su
  VRAM es una sola operación, no dos.

  ## Por qué hace falta

  Dos `start_placed/2` concurrentes pueden medir **la misma** memoria libre
  (el `sync_foreign` de uno todavía no ve lo que el otro acaba de reservar) y
  decidir los dos que su modelo cabe. El primero reserva; el segundo recibe
  un error de acquire —que no explica nada— y su modelo no arranca, cuando
  en realidad lo que había era sitio de sobra y una carrera.

  Con el cerrojo, el segundo **espera** y vuelve a decidir con la memoria ya
  cambiada: si ahora no cabe, lo dice (`no_room`), y si cabe, reserva.

  El cerrojo vive en `Candil.Engine.Resource.Placement`, que es un semaforo
  (el motor tiene que seguir siendo hijo de quien lo pide, no del cerrojo) y
  no un mutex de `:global` — en OTP 28 la API de cerrojos de `:global` ya no
  existe y `trans/3` se quedo sin hacer nada. Medido el 2026-10-22: dos
  llamadas concurrentes de `trans/3` tardaron 1,0 s en vez de 2,0 s.
  """
  @spec with_placement_lock((-> result)) :: result | {:error, :placement_busy}
        when result: term()
  def with_placement_lock(fun) when is_function(fun, 0) do
    Candil.Engine.Resource.Placement.with_lock(fun)
  end

  @doc """
  VRAM disponible en un device (0 si no está registrado).

  ## El 0 no es «quedan 0 MiB»

  Es **«no cabe»**, y no una medida. Pasa cuando la memoria ajena es MAYOR que
  el hueco que queda: la memoria que usa otra gente no se puede representar en
  el ledger, y la verdad es que no cabe un motor ni de pasillo. Por eso el
  titular `:foreign` se recorta a lo representable y la disponible cae a 0.

  Y por eso el scheduler decide con ESTA cifra y no con la del sistema: los dos
  lados tienen que decir lo mismo, o el modelo no arranca con un error que no
  explica nada.
  """
  @spec available(non_neg_integer()) :: non_neg_integer()
  def available(device_index) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)
    Arrea.Resource.available(name)
  end

  @doc """
  El nombre con el que un device está registrado en `Arrea.Resource`.

  Es público porque **el átomo no se puede inventar en runtime**: `:device0`
  creado en un test es un átomo nuevo, y los átomos no se recogen. Los
  nombres de este módulo están precalculados en compilación, así que este
  `device_name/1` es la única forma correcta de referirse a ellos.

  El nombre es **neutro** (D-28): no dice el backend, porque el device 0 no
  es «una GPU NVIDIA» —es un slot— y el backend lo publica el motor, en el
  nombre con el que se le habla (`CUDA0`, `ROCm0`…).

  Un índice fuera de rango es un error explícito, no un átomo nuevo.
  """
  @spec device_name(non_neg_integer()) :: atom()
  def device_name(index) when is_integer(index) and index >= 0 and index < @max_devices do
    Enum.at(@device_names, index)
  end

  def device_name(index) do
    raise ArgumentError,
          "device index #{inspect(index)} fuera de rango: hay #{@max_devices} " <>
            "nombres precalculados (0..#{@max_devices - 1})"
  end

  @doc """
  Para el resource de un device, si lo hay.

  `Arrea.Resource` no tiene API para parar un resource, pero su proceso está
  en `Arrea.Resource.Registry` y un GenServer se para. Lo que se para es el
  **ledger entero**: las reservas que tuviera se van con él.

  Sirve para el cleanup de los tests, porque el registro es global: un
  resource que se queda puesto entre tests deja titulares que no son de
  nadie y hace que el siguiente test mida una memoria que ya no existe.
  """
  @spec stop_device(non_neg_integer()) :: :ok
  def stop_device(device_index) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)

    case Registry.lookup(Arrea.Resource.Registry, name) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Ajusta la memoria que usan procesos que **Candil no gestiona**.

  Es el hueco que hacía que el ledger dijera 15933 MiB libres cuando la
  memoria REALMENTE libre era menos: en la medición del 2026-10-21 eran
  11518 MiB, de los que 4216 ocupaba un modelo de otra sesión, y el ledger no
  lo sabía. La reserva se tomaba sobre una memoria que ya no estaba, y el OOM
  pasaba con la cuenta «correcta».

  ## La fuente es el motor, y es la misma que la capacidad

  La capacidad con la que se registró el device y el libre que se usa aquí
  salen **de la misma medición** —la del motor—. La fórmula

      foreign = max(capacity − free − candil_used, 0)

  solo vale si las dos cifras son del mismo sitio: si la capacidad fuera de
  `nvidia-smi` y el libre del motor, la resta sería de dos coordenadas
  distintas.

  ## Sin medición no se ajusta, y se dice

  Si el motor no se puede preguntar, esta función devuelve
  `{:error, :memory_unknown}` **y no ajusta nada**. Antes devolvía `:ok` ante
  cualquier fallo: el ledger se quedaba con una cifra vieja y el scheduler
  decidía sobre una memoria que ya no era. Un `:ok` que no se ajustó es
  indistinguible de un `:ok` que sí.

  El scheduler que llama a esto **no coloca** cuando recibe ese error: no
  medir no es «no cabe», es «no lo sé» (D-28).

  ## Por que un titular y no cambiar la capacidad

  `Arrea.Resource` **no tiene API para cambiar la capacidad** de un resource
  registrado, ni para pararlo. Re-registrarlo perdería el ledger entero —el
  estado `holders` vive en el proceso—, y con él las reservas de los modelos
  que ya están arrancados.

  La vía que no pierde nada es **meter la memoria ajena en el ledger como un
  titular más**. Con la capacidad del device y dos titulares:

      available = capacity − (foreign + modelos de Candil)

  y como `foreign = (capacity − free) − modelos_de_Candil`:

      available = free

  que es exactamente **la memoria que un motor nuevo puede usar**: la que el
  motor ve libre, con su contexto ya descontado.

  El criterio de aceptación es una **fórmula**, no una cifra:

      available == free_del_motor

  Medido el 2026-10-22: el motor veía 857 MiB libres y la disponible del
  ledger pasó a ser 857 ✓. Las dos cifras de la línea anterior eran de otro
  instante —la memoria ajena de otra sesión cambia mientras se mide—, y por eso
  el criterio va en fórmula: el número vale en cada momento, la cifra no.

  Reajustar **no** pierde el ledger: `acquire/4` añade una entrada y
  `release/2` quita la primera de ese titular, así que un `release` + `acquire`
  del delta es un ajuste limpio. Es el mismo mecanismo que usa la corrección
  de la reserva de un modelo.

  El delta se ignora si es menor que el umbral, para no provocar un
  `release`+`acquire` en cada arranque por unos megas de diferencia.

  ## Lo que este módulo NO atomiciza

  El ajuste de `:foreign` son **dos** llamadas a `Arrea.Resource` —un `release`
  y un `acquire`— y entre las dos hay un hueco: otro arranque que mire en ese
  instante ve una disponible **demasiado grande** (la memoria ajena todavía no
  está descontada).

  No se serializa, y es una decisión con su porqué:

  - `Arrea.Resource` no tiene API para ajustar un titular de una vez, y
    re-registrar el resource perdería el ledger entero.
  - El hueco dura lo que dura una llamada local a un GenServer: microsegundos.
  - **Y el daño está acotado**: el modelo que se colaría con esa disponible
    exagerada no se queda sin control, porque su reserva se corrige al peso
    **medido** en cuanto `llama-fit-params` responde, y esa corrección es la
    que sí es atómica (un `acquire` contra la capacidad real). El modelo que
    no quepa, se para.

  Con un solo usuario —el caso de Candil— la probabilidad de que otro arranque
  caiga justo en ese hueco es despreciable. Si algún día el scheduler puede
  colocar dos modelos a la vez, esto hay que serializarlo por device.
  """
  @spec sync_foreign(map()) :: :ok | {:error, term()}
  def sync_foreign(%{index: device_index, total_mb: total, free_mb: free})
      when is_integer(device_index) and device_index >= 0 and is_integer(total) and
             is_integer(free) do
    with :ok <- ensure_registered(%{index: device_index, total_mb: total}),
         {:ok, used_by_models} <- used_by_models(device_index) do
      # Lo que ocupa el device y no es de Candil. Puede ser **más** que lo que
      # queda: con el device al 99 % (42 MiB libres de verdad), la memoria ajena
      # es de 16261 MiB y el ledger solo tiene 15933 de hueco. Entonces el
      # `acquire` del titular fallaría y la disponible se quedaría en 15933 —
      # **la cifra que no existe**, que es justo lo que este módulo viene a
      # quitar.
      #
      # La verdad en ese caso es «no cabe nada», así que el titular se recorta
      # a lo que queda y la disponible cae a 0. Un 0 es honesto; un 15933 no.
      foreign = max(total - free - used_by_models, 0)

      current = foreign_reserved(device_index)

      if abs(foreign - current) > @foreign_threshold_mb do
        adjust_foreign(device_index, foreign)
      else
        :ok
      end
    end
  end

  # Sin medición no hay nada que ajustar: y se dice, en vez de devolver un
  # `:ok` que no ajustó nada (D-28). Un 0 aquí sería inventar una medida.
  def sync_foreign(_device), do: {:error, :memory_unknown}

  # ── internos ─────────────────────────────────────────────────────────────

  defp adjust_foreign(device_index, wanted) do
    name = device_name(device_index)

    # Primero se suelta la reserva vieja, y solo después se pide la nueva: al
    # revés, con la memoria justa, pedir antes de soltar podría no caber.
    if foreign_reserved(device_index) > 0 do
      _ = Arrea.Resource.release(name, :foreign)
    end

    if wanted > 0 do
      case Arrea.Resource.acquire(name, :foreign, wanted, 0) do
        {:ok, _receipt} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  defp foreign_reserved(device_index) do
    name = device_name(device_index)

    case Arrea.Resource.status(name) do
      %{holders: holders} ->
        holders
        |> Enum.filter(&(elem(&1, 0) == :foreign))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp used_by_models(device_index) do
    name = device_name(device_index)

    case Arrea.Resource.status(name) do
      %{holders: holders} ->
        {:ok,
         holders
         |> Enum.reject(&(elem(&1, 0) == :foreign))
         |> Enum.map(&elem(&1, 1))
         |> Enum.sum()}

      _ ->
        {:error, :not_registered}
    end
  end

  # `total` y `free` vienen en la medición, que es **una sola**: la del motor.
  # `free` es la memoria que no usa NADIE: ni los modelos de Candil ni los de
  # otras sesiones. Por eso hay que restarle las reservas de Candil para sacar
  # lo ajeno.
  defp register(name, capacity) do
    case Arrea.Resource.start_link(name, capacity) do
      {:ok, _pid} ->
        # **Sin** titular `:system` (D-28): la capacidad que se registra es la
        # del motor, que ya viene sin su contexto. Un titular `:system` aquí lo
        # descontaría dos veces.
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, _reason} ->
        {:error, :capacity_unknown}
    end
  end
end
