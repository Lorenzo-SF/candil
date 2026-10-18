defmodule Candil.Scheduler.SignalTest do
  use ExUnit.Case, async: true

  alias Candil.Scheduler.Signal

  test "for_local estima el tamaño del context_size" do
    model = %Candil.Model{alias: :test, type: :local, context_size: 4096, engine: :llama_cpp}
    signal = Signal.for_local(model)
    assert signal.kind == :local
    # 4096/1024 * 4
    assert signal.size_mb == 16
    assert signal.startup_s == 30
  end

  test "for_local usa vram_mb si está declarado" do
    model = %Candil.Model{
      alias: :test,
      type: :local,
      context_size: 4096,
      vram_mb: 8000,
      engine: :llama_cpp
    }

    signal = Signal.for_local(model)
    assert signal.size_mb == 8000
  end

  test "size_mb/1 devuelve 0 si es nil" do
    assert Signal.size_mb(%Signal{size_mb: nil}) == 0
    assert Signal.size_mb(%Signal{size_mb: 100}) == 100
  end

  test "for_remote lee coste y rpm del provider" do
    model = %Candil.Model{alias: :remote, type: :remote}
    signal = Signal.for_remote(model, %{cost_eur: 0.5, rpm: 60})
    assert signal.kind == :remote
    assert signal.cost_eur == 0.5
    assert signal.rpm == 60
  end
end
