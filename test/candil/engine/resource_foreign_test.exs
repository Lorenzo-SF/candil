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
  la memoria ajena como **otro titular**, al lado de `:system`. Con eso:

      available = free_real − overhead

  que es exactamente la memoria que un motor nuevo puede usar. El criterio va
  en fórmula y no en cifra: la memoria ajena de otra sesión cambia mientras
  se mide, y un número fijo de un instante no sirve de criterio.

  ## La GPU de este test es de mentira

  Las cifras vienen de un `nvidia-smi` falso (`Candil.FakeGPU`), no de la
  máquina. Sin eso el test dependía del hardware de quien lo corría: en CI
  fallaba con `{:error, :capacity_unknown}` porque el runner no tiene GPU, y
  en local fallaba cuando otra sesión tenía la tarjeta llena. Y el caso
  interesante —**la GPU llena**, que es donde el titular `:foreign` no cabe
  en el ledger— solo se podía ver por suerte. Con la GPU falsa se ve siempre.
  """

  use ExUnit.Case, async: false

  alias Candil.Engine.Resource
  alias Candil.FakeGPU

  @moduletag :tmp_dir

  @total 16_303
  @free 16_000
  @overhead 370

  setup %{tmp_dir: tmp_dir} do
    # El resource vive en un registro global, asi que cada test necesita
    # empezar limpio: se para el del device y se vuelve a registrar.
    device = 0
    Resource.stop_device(device)
    on_exit(fn -> Resource.stop_device(device) end)

    FakeGPU.install(tmp_dir, total_mb: @total, free_mb: @free)
    on_exit(&FakeGPU.uninstall/0)

    %{device: device}
  end

  # El nombre con el que `Arrea.Resource` registra el device. Lo da el propio
  # módulo (`device_name/1`), que los precalcula en compilación: aquí no se
  # crea ningún átomo en runtime.
  defp device_name(device), do: Resource.device_name(device)

  describe "la memoria ajena" do
    test "el ledger descuenta lo que no es de Candil", %{device: device} do
      # Se registra el device con la capacidad de `nvidia-smi` y se reserva el
      # overhead como `:system`, que es lo que hace `ensure_registered/1`.
      :ok = Resource.ensure_registered(device)

      # Sin memoria ajena, la disponible es la del motor: total − overhead.
      assert Resource.available(device) == @total - @overhead
    end

    test "un titular ajeno baja la disponible", %{device: device} do
      :ok = Resource.ensure_registered(device)
      name = device_name(device)

      # 4216 MiB de un proceso que Candil no gestiona, como titular `:foreign`.
      {:ok, _receipt} = Arrea.Resource.acquire(name, :foreign, 4216, 0)

      assert Resource.available(device) == @total - @overhead - 4216
    end

    test "el reajuste deja la disponible en la memoria real menos el overhead", %{
      device: device
    } do
      :ok = Resource.ensure_registered(device)

      # El criterio de aceptacion del plan, con los numeros de AHORA: la
      # disponible tiene que ser la memoria libre REAL menos el contexto CUDA
      # del motor. Antes de este reajuste era el total del device, y por eso
      # contaba memoria que ya no estaba.
      #
      # Con un tope en 0: si la GPU está tan llena que no queda ni el overhead
      # del motor, la verdad es «no cabe nada», y un 0 es honesto. Un número
      # negativo en un contador de megas no lo es.
      free_real = free_of(device)

      :ok = Resource.sync_foreign(device)

      assert Resource.available(device) == max(free_real - @overhead, 0)
    end

    test "la memoria que usa otra sesion se descuenta sola", %{device: device} do
      :ok = Resource.ensure_registered(device)

      # La memoria ajena son 16303 − 16000 = 303 MiB: lo que usa un proceso que
      # Candil no gestiona. Sin el `:foreign`, la disponible sería la del
      # total (15933) y contaría una memoria que ya no está.
      :ok = Resource.sync_foreign(device)

      assert Resource.available(device) == @free - @overhead

      # Y el ledger lo sabe: el titular ajeno está, y es el que lo sostiene.
      status = Arrea.Resource.status(device_name(device))

      assert :foreign in Enum.map(status.holders, &elem(&1, 0))
    end

    test "la memoria de Candil no se cuenta como ajena", %{device: device} do
      :ok = Resource.ensure_registered(device)

      # Un modelo de Candil ocupando 5000 MiB. La memoria AJENA es la que
      # queda de la real menos lo que ocupa Candil:
      #
      #     foreign = (total − free_real) − modelos_de_Candil
      #
      # Sin la resta de los modelos, los 5000 se descontarían **dos veces**
      # (una como modelo y otra como ajenos), y el ledger afirmaría menos
      # memoria de la que hay.
      {:ok, _receipt} = Resource.acquire(device, {:coder, 9999}, 5000)

      :ok = Resource.sync_foreign(device)

      # La disponible es el total menos el overhead y menos el modelo, y el
      # titular `:foreign` no está (aquí no hay nada ajeno: 16303 − 16000 son
      # 303 MiB, y menos los 5000 del modelo, el resto es 0).
      assert Resource.available(device) == @total - @overhead - 5000

      status = Arrea.Resource.status(device_name(device))
      holders = Enum.map(status.holders, &elem(&1, 0))

      assert {:coder, 9999} in holders
      assert :system in holders
    end

    test "la memoria ajena se reajusta sola", %{device: device} do
      # `sync_foreign/1` es lo que llama el scheduler antes de decidir. Aqui se
      # comprueba con lo que hay: sin `nvidia-smi` que diga otra cosa, el
      # reajuste deja el ledger como estaba.
      :ok = Resource.ensure_registered(device)
      before = Resource.available(device)

      :ok = Resource.sync_foreign(device)

      after_sync = Resource.available(device)

      # No puede ser mas grande que antes (el ledger solo resta memoria), y no
      # puede haber dejado el resource en un estado imposible.
      assert after_sync <= before
      assert after_sync >= 0
    end
  end

  describe "con la GPU llena" do
    setup %{tmp_dir: tmp_dir} do
      # La GPU de verdad, casi llena: 42 MiB libres. Es el caso que en la
      # maquina real solo se ve por casualidad, cuando otra sesion tiene la
      # tarjeta ocupada.
      FakeGPU.install(tmp_dir, total_mb: @total, free_mb: 42)
      :ok
    end

    test "la disponible es 0, no la cifra que no existe", %{device: device} do
      # El hueco que queda tras `:system` son 15933 MiB, y la memoria ajena son
      # 16261: **no cabe**. Sin el recorte, el `acquire` del titular fallaba,
      # el error se tragaba, y la disponible se quedaba en 15933 — la del
      # total del device, que no existía. Justo la mentira que este módulo
      # viene a quitar.
      :ok = Resource.ensure_registered(device)

      :ok = Resource.sync_foreign(device)

      assert Resource.available(device) == 0
    end

    test "y ningun motor puede arrancar con la GPU llena", %{device: device} do
      # La consecuencia de lo de arriba: con la GPU llena, no hay sitio. Un
      # modelo que pida VRAM no puede arrancar, y el error tiene que decirlo.
      :ok = Resource.ensure_registered(device)
      :ok = Resource.sync_foreign(device)

      name = device_name(device)

      assert {:error, _reason} = Arrea.Resource.acquire(name, {:coder, 9999}, 512, 0)
    end
  end

  describe "el estado de la reserva" do
    test "un modelo de Candil se distingue del ajeno", %{device: device} do
      :ok = Resource.ensure_registered(device)
      name = device_name(device)

      {:ok, _} = Resource.acquire(device, {:coder, 9999}, 5000)

      status = Arrea.Resource.status(name)

      # El titular de un modelo es un tuple, y el ajeno es un atomo: la
      # identidad es exacta y `release` no se confunde.
      holders = Enum.map(status.holders, &elem(&1, 0))

      assert {:coder, 9999} in holders
      assert :system in holders
    end
  end

  # El total que ve `nvidia-smi`. El test no lo inventa: lo lee del mismo sitio
  # que lo lee el codigo.
  defp free_of(device) do
    [d] = Candil.Scheduler.Devices.detect() |> Enum.filter(&(&1.index == device))
    d.free_mb
  end
end
