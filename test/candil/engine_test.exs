defmodule Candil.EngineTest.NoopLauncher do
  @moduledoc false
  @behaviour Candil.Engine.Launcher

  @impl true
  def launch(_engine, _model), do: {:ok, %{base_url: "http://127.0.0.1:65535", pid: nil}}
end

defmodule Candil.EngineTest.FailingLauncher do
  @moduledoc false
  @behaviour Candil.Engine.Launcher

  @impl true
  def launch(_engine, _model), do: {:error, :launcher_failed}
end

defmodule Candil.EngineTest do
  use ExUnit.Case, async: false

  alias Candil.Engine

  describe "binary_dir/1" do
    test "returns configured binary_dir" do
      engine = %Engine{alias: :test, binary_dir: "/custom/path"}
      assert Engine.binary_dir(engine) == "/custom/path"
    end

    test "falls back to ~/.apero/llm/bin when binary_dir is nil" do
      engine = %Engine{alias: :test, binary_dir: nil}
      expected = Path.join([System.user_home!(), ".apero", "llm", "bin"])
      assert Engine.binary_dir(engine) == expected
    end
  end

  describe "binary_path/1" do
    test "returns full path to llama-server" do
      engine = %Engine{alias: :test, binary_dir: "/usr/local/bin"}
      assert Engine.binary_path(engine) == "/usr/local/bin/llama-server"
    end

    test "uses binary_dir from engine" do
      engine = %Engine{alias: :test, binary_dir: "/opt/llm"}
      assert Engine.binary_path(engine) == "/opt/llm/llama-server"
    end
  end

  describe "binary_exists?/1" do
    test "returns true when binary exists" do
      # Create a temp file named llama-server to simulate the binary
      tmp_dir = Path.join(System.tmp_dir(), "candil_test_#{:rand.uniform(9999)}")
      File.mkdir_p!(tmp_dir)
      tmp_path = Path.join(tmp_dir, "llama-server")
      File.write!(tmp_path, "")

      engine = %Engine{alias: :test, binary_dir: tmp_dir}

      try do
        assert Engine.binary_exists?(engine) == true
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "returns false when binary does not exist" do
      engine = %Engine{alias: :test, binary_dir: "/nonexistent/path"}
      refute Engine.binary_exists?(engine)
    end
  end

  describe "start/2" do
    test "returns error when binary does not exist" do
      engine = %Engine{alias: :test, binary_dir: "/nonexistent"}

      model = %Candil.Model{
        alias: :test_model,
        type: :local,
        model_dir: "/models",
        filename: "test.gguf"
      }

      assert {:error, _} = Engine.start(engine, model)
    end
  end

  describe "struct fields" do
    test "has :launcher field with default nil" do
      engine = %Engine{alias: :test}
      assert Map.has_key?(engine, :launcher)
      assert engine.launcher == nil
    end

    test "accepts a launcher module" do
      engine = %Engine{alias: :test, launcher: Candil.EngineTest.NoopLauncher}
      assert engine.launcher == Candil.EngineTest.NoopLauncher
    end
  end

  describe "launcher branch in do_start/2" do
    test "invokes launcher.launch/2 when configured and bypasses binary check" do
      model_alias = :launcher_test_model

      engine = %Engine{
        alias: :launcher_test,
        # Binary does not exist AND use_precompiled is false — would
        # normally return an error. The launcher branch must short-circuit.
        binary_dir: "/nonexistent",
        use_precompiled: false,
        host: "127.0.0.1",
        port: 65_535,
        launcher: Candil.EngineTest.NoopLauncher
      }

      model = %Candil.Model{
        alias: model_alias,
        type: :local,
        model_dir: "/models",
        filename: "launcher_test.gguf"
      }

      assert :ok = Engine.start(engine, model)

      assert [{pid, _}] = Registry.lookup(Candil.Registry, model_alias)
      assert GenServer.call(pid, :base_url) == "http://127.0.0.1:65535"
      assert Engine.base_url(model_alias) == "http://127.0.0.1:65535"

      :ok = Engine.stop(model_alias)
    end

    test "propagates launcher errors verbatim" do
      engine = %Engine{
        alias: :failing_launcher_test,
        binary_dir: "/nonexistent",
        use_precompiled: false,
        launcher: Candil.EngineTest.FailingLauncher
      }

      model = %Candil.Model{
        alias: :failing_launcher_model,
        type: :local,
        model_dir: "/models",
        filename: "x.gguf"
      }

      assert {:error, :launcher_failed} = Engine.start(engine, model)
    end

    test "returns {:error, :not_running} when launcher was never called" do
      assert Engine.stop(:never_launched) == {:error, :not_running}
    end
  end

  describe "stop/1" do
    test "returns {:error, :not_running} when engine not running" do
      assert Engine.stop(:nonexistent_model) == {:error, :not_running}
    end
  end

  describe "healthy?/1" do
    test "returns false when engine not running" do
      refute Engine.healthy?(:nonexistent_model)
    end
  end

  describe "base_url/1" do
    test "returns nil when engine not running" do
      assert Engine.base_url(:nonexistent_model) == nil
    end
  end
end
