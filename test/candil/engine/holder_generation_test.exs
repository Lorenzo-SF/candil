defmodule Candil.Engine.HolderGenerationTest do
  @moduledoc """
  El titular de la reserva lleva una **generación**, porque `{alias, port}` no
  es único en el tiempo.

  El caso: el puerto se reutiliza, el `terminate/2` del server viejo llega
  tarde, y su `release/2` —que quita la primera entrada de ese titular—
  suelta la reserva **del modelo nuevo**, que la estaba usando. Con la
  generación, la reserva vieja solo la suelta quien la pidió.
  """

  use ExUnit.Case, async: false

  alias Candil.Engine
  alias Candil.Engine.Resource
  alias Candil.FakeGPU

  @moduletag :tmp_dir

  @total 16_303
  @overhead 370

  setup %{tmp_dir: tmp_dir} do
    FakeGPU.install(tmp_dir, total_mb: @total, free_mb: 16_000)
    on_exit(&FakeGPU.uninstall/0)

    Resource.stop_device(0)
    on_exit(fn -> Resource.stop_device(0) end)

    :ok
  end

  defp engine do
    %Engine{alias: :coder_e, binary: "/nonexistent/llama-server", host: "127.0.0.1", port: 9999}
  end

  defp model do
    %Candil.Model{
      alias: :coder,
      type: :local,
      engine: :coder_e,
      context_size: 4096,
      port: 9999,
      model_dir: "/nonexistent",
      filename: "m.gguf"
    }
  end

  test "dos titulares del mismo modelo NO son el mismo" do
    h1 = Engine.holder(model(), engine())
    h2 = Engine.holder(model(), engine())

    # El alias y el puerto son los mismos —el modelo y el puerto no han
    # cambiado—, pero la generación es distinta.
    assert {alias1, port1, gen1} = h1
    assert {alias2, port2, gen2} = h2

    assert alias1 == alias2
    assert port1 == port2
    refute gen1 == gen2
    assert is_reference(gen1)
  end

  test "un release tardío no suelta la reserva del modelo nuevo", %{tmp_dir: tmp_dir} do
    _ = tmp_dir
    :ok = Resource.ensure_registered(0)

    old_holder = Engine.holder(model(), engine())
    new_holder = Engine.holder(model(), engine())

    # El modelo nuevo reserva 5000 MiB con SU titular.
    {:ok, _receipt} = Resource.acquire(0, new_holder, 5000)

    available = Resource.available(0)
    assert available == @total - @overhead - 5000

    # Y ahora llega el `terminate/2` del server VIEJO, con su titular viejo.
    # Sin generación, `release/2` habría quitado la primera entrada de
    # `{alias, port}` —que ahora es la del modelo nuevo— y la habría soltado.
    _ = Resource.release(0, old_holder)

    assert Resource.available(0) == available,
           "un release de un titular viejo soltó la reserva del nuevo"

    # Y el titular bueno sí la suelta.
    _ = Resource.release(0, new_holder)
    assert Resource.available(0) == @total - @overhead
  end
end
