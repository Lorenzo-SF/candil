defmodule Candil.EngineTest do
  use ExUnit.Case, async: true

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
