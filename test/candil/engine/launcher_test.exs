defmodule Candil.Engine.LauncherTest.NoopLauncher do
  @moduledoc false
  @behaviour Candil.Engine.Launcher

  @impl true
  def launch(_engine, _model), do: {:ok, %{base_url: "http://127.0.0.1:65535", pid: nil}}
end

defmodule Candil.Engine.LauncherTest.ErrorLauncher do
  @moduledoc false
  @behaviour Candil.Engine.Launcher

  @impl true
  def launch(_engine, _model), do: {:error, :external_failure}
end

defmodule Candil.Engine.LauncherTest do
  use ExUnit.Case, async: true

  alias Candil.Engine
  alias Candil.Engine.Launcher

  alias Candil.Engine.LauncherTest.{ErrorLauncher, NoopLauncher}

  describe "behaviour contract" do
    test "declares launch/2 as a callback" do
      callbacks = Launcher.behaviour_info(:callbacks)
      assert {:launch, 2} in callbacks
    end
  end

  describe "Engine struct :launcher field" do
    test "defaults to nil" do
      engine = %Engine{alias: :test}
      assert engine.launcher == nil
    end

    test "accepts a module implementing the behaviour" do
      engine = %Engine{alias: :test, launcher: NoopLauncher}
      assert engine.launcher == NoopLauncher
    end
  end

  describe "dummy launcher implementation" do
    test "launch/2 returns the documented success shape" do
      engine = %Engine{alias: :noop}
      model = %Candil.Model{alias: :m, type: :local, model_dir: "/m", filename: "m.gguf"}

      assert {:ok, %{base_url: url, pid: pid}} = NoopLauncher.launch(engine, model)

      assert is_binary(url)
      assert is_nil(pid)
    end

    test "error launcher returns the documented error shape" do
      engine = %Engine{alias: :err}
      model = %Candil.Model{alias: :m, type: :local, model_dir: "/m", filename: "m.gguf"}

      assert {:error, :external_failure} = ErrorLauncher.launch(engine, model)
    end
  end
end
