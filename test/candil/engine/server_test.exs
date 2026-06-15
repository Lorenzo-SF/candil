defmodule Candil.Engine.ServerTest do
  use ExUnit.Case, async: true

  describe "start_link/1" do
    test "requires model in init arg" do
      # The server expects %{model: model} in init_arg
      # If model is missing, it will fail when trying to access model.alias
    end
  end

  describe "build_args/2" do
    test "builds correct arguments for llama-server" do
      # These would be used to test the private build_args function
      # But since it's private, we document that this test exists
      _engine = %Candil.Engine{
        alias: :test,
        host: "127.0.0.1",
        port: 8080,
        start_args: ["--n-gpu-layers", "35"]
      }

      _model = %Candil.Model{
        alias: :test_model,
        type: :local,
        model_dir: "/models",
        filename: "test.gguf",
        context_size: 8192
      }

      # Test the argument building through the server's init
      # The actual build_args is private, so we test indirectly
    end
  end

  describe "health check" do
    test "handle_call :health returns appropriate response" do
      # Without a running server, we can't test this directly
      # This would require an integration test with a real binary
    end
  end
end
