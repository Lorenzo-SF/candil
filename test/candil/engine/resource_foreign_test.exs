defmodule Candil.Engine.ResourceForeignTest do
  @moduledoc """
  El ledger tiene que ver la **memoria real**, incluida la que usan procesos
  que Candil no gestiona.

  Medido el 2026-10-21: con un modelo de otra sesión ocupando 4216 MiB, el
  ledger decía **15933 MiB libres** y los reales eran **11518**. La reserva se
  tomaba sobre una memoria que ya no estaba, y el OOM pasaba con la cuenta
  «correcta».

  La solución no es cambiar la capacidad del resource —`Arrea.Resource` no
  tiene API para eso, y re-registrarlo perdería el ledger entero—, sino meter
  la memoria ajena en el ledger como **otro titular**. Con eso:

      available = capacity − (foreign + modelos de Candil)

  y como `foreign = (capacity − free) − modelos_de_Candil`:

      available = free

  que es la memoria que un motor nuevo puede usar: la que el motor ve libre.

  ## La fuente es el motor (D-28)

  Desde D-28 la capacidad y el libre los publica **el motor**
  (`llama-server --list-devices`), no `nvidia-smi`: son la misma medición, y
  la capacidad del motor ya viene sin su contexto de CUDA. Por eso aquí **no
  hay titular `:system`** y **no hay constante de overhead**.

  ## La GPU de este test es de mentira

  Las cifras vienen de un `nvidia-smi` falso y de un **motor** falso
  (`Candil.FakeGPU`), no de la máquina. Sin eso el test dependía del hardware
  de quien lo corría: en CI fallaba con `{:error, :capacity_unknown}` porque
  el runner no tiene GPU, y en local fallaba cuando otra sesión tenía la
  tarjeta llena. Y el caso interesante —**la GPU llena**, que es donde el
  titular `:foreign` no cabe en el ledger— solo se podía ver por suerte. Con la
  GPU falsa se ve siempre.
  """

  use ExUnit.Case, async: false

  alias Candil.Engine.Resource
  alias Candil.FakeGPU

  @moduletag :tmp_dir

  # Lo que ve el **motor**: el total ya sin su contexto de CUDA, y el libre.
  @engine_total 15_933
  @engine_free 15_000

  setup %{tmp_dir: tmp_dir} do
    # El resource vive en un registro global, asi que cada test necesita
    # empezar limpio: se para el del device y se vuelve a registrar.
    device = 0
    Resource.stop_device(device)
    on_exit(fn -> Resource.stop_device(device) end)

    FakeGPU.install(tmp_dir, total_mb: 16_303, free_mb: 16_000)
    on_exit(&FakeGPU.uninstall/0)

    %{device: device, binary: engine_binary(tmp_dir)}
  end

  # El nombre con el que `Arrea.Resource` registra el device. Lo da el propio
  # módulo (`device_name/1`), que los precalcula en compilación: aquí no se
  # crea ningún átomo en runtime.
  defp device_name(device), do: Resource.device_name(device)

  # La medición del device, tal y como la publica el motor. Es **dato**, no
  # una forma de medir: el ledger no sabe de dónde salen las cifras.
  defp measurement(binary, device) do
    {:ok, record} = Candil.Detector.EngineDevices.device(binary, device)
    record
  end

  defp engine_binary(tmp_dir), do: FakeGPU.install_engine(tmp_dir)

  describe "la memoria ajena" do
    test "el ledger se registra con la capacidad del motor", %{
      device: device,
      binary: binary
    } do
      # Sin nada reservado, la disponible es la capacidad: la del motor, que
      # ya viene sin su contexto. **No** hay titular `:system` que la baje
      # (D-28).
      :ok = Resource.ensure_registered(measurement(binary, device))

      assert Resource.available(device) == @engine_total
    end

    test "un titular ajeno baja la disponible", %{device: device, binary: binary} do
      :ok = Resource.ensure_registered(measurement(binary, device))
      name = device_name(device)

      # 4216 MiB de un proceso que Candil no gestiona, como titular `:foreign`.
      {:ok, _receipt} = Arrea.Resource.acquire(name, :foreign, 4216, 0)

      assert Resource.available(device) == @engine_total - 4216
    end

    test "el reajuste deja la disponible en la memoria que ve el motor", %{
      device: device,
      binary: binary
    } do
      :ok = Resource.ensure_registered(measurement(binary, device))

      # El criterio de aceptacion del plan, con los numeros de AHORA: la
      # disponible tiene que ser la memoria libre REAL. Antes de este reajuste
      # era el total del device, y por eso contaba memoria que ya no estaba.
      #
      # Con un tope en 0: si el device está tan lleno que no queda nada, la
      # verdad es «no cabe nada», y un 0 es honesto. Un número negativo en un
      # contador de megas no lo es.
      :ok = Resource.sync_foreign(measurement(binary, device))

      assert Resource.available(device) == max(@engine_free, 0)
    end

    test "la memoria que usa otra sesion se descuenta sola", %{
      device: device,
      binary: binary
    } do
      :ok = Resource.ensure_registered(measurement(binary, device))

      # La memoria ajena son 15933 − 15000 = 933 MiB: lo que usa un proceso que
      # Candil no gestiona. Sin el `:foreign`, la disponible sería la del
      # total y contaría una memoria que ya no está.
      :ok = Resource.sync_foreign(measurement(binary, device))

      assert Resource.available(device) == @engine_free

      # Y el ledger lo sabe: el titular ajeno está, y es el que lo sostiene.
      status = Arrea.Resource.status(device_name(device))

      assert :foreign in Enum.map(status.holders, &elem(&1, 0))
    end

    test "la memoria de Candil no se cuenta como ajena", %{device: device, binary: binary} do
      :ok = Resource.ensure_registered(measurement(binary, device))

      # Un modelo de Candil ocupando 5000 MiB. La memoria AJENA es la que
      # queda de la real menos lo que ocupa Candil:
      #
      #     foreign = (total − free_real) − modelos_de_Candil
      #
      # Sin la resta de los modelos, los 5000 se descontarían **dos veces**
      # (una como modelo y otra como ajenos), y el ledger afirmaría menos
      # memoria de la que hay.
      {:ok, _receipt} = Resource.acquire(measurement(binary, device), {:coder, 9999}, 5000)

      :ok = Resource.sync_foreign(measurement(binary, device))

      # La disponible es el total menos el modelo, y el titular `:foreign` no
      # está (aquí no hay nada ajeno: 15933 − 15000 son 933 MiB, y menos los
      # 5000 del modelo, el resto es 0).
      assert Resource.available(device) == @engine_total - 5000

      status = Arrea.Resource.status(device_name(device))
      holders = Enum.map(status.holders, &elem(&1, 0))

      assert {:coder, 9999} in holders
      refute :foreign in holders
    end

    test "la memoria ajena se reajusta sola", %{device: device, binary: binary} do
      # `sync_foreign/1` es lo que llama el scheduler antes de decidir. Aqui se
      # comprueba con lo que hay: sin nada que diga otra cosa, el reajuste
      # deja el ledger como estaba.
      :ok = Resource.ensure_registered(measurement(binary, device))
      before = Resource.available(device)

      :ok = Resource.sync_foreign(measurement(binary, device))

      after_sync = Resource.available(device)

      # No puede ser mas grande que antes (el ledger solo resta memoria), y no
      # puede haber dejado el resource en un estado imposible.
      assert after_sync <= before
      assert after_sync >= 0
    end
  end

  describe "sin medición" do
    test "sync_foreign lo dice, y no deja una cifra vieja", %{
      device: device,
      binary: binary
    } do
      :ok = Resource.ensure_registered(measurement(binary, device))
      before = Resource.available(device)

      # Un device que no se puede medir: no hay `total_mb`, y una medición
      # sin total no es una medición.
      assert {:error, :memory_unknown} =
               Resource.sync_foreign(%{index: device, total_mb: nil, free_mb: nil})

      # Y el ledger se queda como estaba: no se ajusta con un 0 inventado.
      assert Resource.available(device) == before
    end
  end

  describe "con la GPU llena" do
    setup %{tmp_dir: tmp_dir} do
      # La GPU de verdad, casi llena: 42 MiB libres. Es el caso que en la
      # maquina real solo se ve por casualidad, cuando otra sesion tiene la
      # tarjeta ocupada.
      FakeGPU.install(tmp_dir, total_mb: 16_303, free_mb: 42)
      :ok
    end

    test "la disponible es la que ve el motor, no la del total", %{
      device: device,
      binary: binary
    } do
      # El hueco que queda son 42 MiB. Antes, con el titular `:system` y su
      # recorte, la disponible caía a 0 —la cifra que no existía— y el error se
      # tragaba. Ahora la disponible es **la que ve el motor**, y un modelo que
      # pide 512 MiB no cabe: que es la verdad.
      :ok = Resource.ensure_registered(measurement(binary, device))

      :ok = Resource.sync_foreign(measurement(binary, device))

      assert Resource.available(device) == 42
    end

    test "y ningun motor puede arrancar con la GPU llena", %{device: device, binary: binary} do
      # La consecuencia de lo de arriba: con la GPU llena, no hay sitio. Un
      # modelo que pida VRAM no puede arrancar, y el error tiene que decirlo.
      :ok = Resource.ensure_registered(measurement(binary, device))
      :ok = Resource.sync_foreign(measurement(binary, device))

      name = device_name(device)

      assert {:error, _reason} = Arrea.Resource.acquire(name, {:coder, 9999}, 512, 0)
    end
  end

  describe "el estado de la reserva" do
    test "un modelo de Candil se distingue del ajeno", %{device: device, binary: binary} do
      :ok = Resource.ensure_registered(measurement(binary, device))
      name = device_name(device)

      {:ok, _} = Resource.acquire(measurement(binary, device), {:coder, 9999}, 5000)

      status = Arrea.Resource.status(name)

      # El titular de un modelo es un tuple, y el ajeno es un atomo: la
      # identidad es exacta y `release` no se confunde.
      holders = Enum.map(status.holders, &elem(&1, 0))

      assert {:coder, 9999} in holders

      # Y **no** hay `:system`: D-28 lo retiró. El overhead del motor ya está
      # fuera de su capacidad, y tenerlo además como titular lo descontaría
      # dos veces.
      refute :system in holders
    end
  end
end
