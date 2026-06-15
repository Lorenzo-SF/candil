defmodule Candil.ModelTest do
  use ExUnit.Case, async: true

  alias Candil.Model

  describe "usage_types/0" do
    test "returns all valid usage types" do
      types = Model.usage_types()
      assert :chat in types
      assert :completion in types
      assert :embeddings in types
      assert :reasoning in types
      assert :vision in types
      assert :code in types
      assert :translation in types
      assert :summarisation in types
    end

    test "returns a list" do
      assert is_list(Model.usage_types())
    end
  end

  describe "file_path/1" do
    test "returns nil for remote models" do
      model = %Model{alias: :gpt4o, type: :remote}
      assert Model.file_path(model) == nil
    end

    test "returns nil when model_dir is nil" do
      model = %Model{alias: :test, type: :local, model_dir: nil, filename: "model.gguf"}
      assert Model.file_path(model) == nil
    end

    test "returns nil when filename is nil" do
      model = %Model{alias: :test, type: :local, model_dir: "/models", filename: nil}
      assert Model.file_path(model) == nil
    end

    test "returns path for local model with both fields" do
      model = %Model{
        alias: :llama3,
        type: :local,
        model_dir: "/models",
        filename: "llama-3-8b-q4.gguf"
      }

      assert Model.file_path(model) == "/models/llama-3-8b-q4.gguf"
    end

    test "joins paths correctly" do
      model = %Model{
        alias: :test,
        type: :local,
        model_dir: "/home/user/models",
        filename: "model.gguf"
      }

      assert Model.file_path(model) == "/home/user/models/model.gguf"
    end
  end

  describe "downloaded?/1" do
    test "returns false for remote models" do
      model = %Model{alias: :gpt4o, type: :remote}
      refute Model.downloaded?(model)
    end

    test "returns false when file does not exist" do
      model = %Model{
        alias: :nonexistent,
        type: :local,
        model_dir: "/tmp",
        filename: "does_not_exist_#{:rand.uniform(9999)}.gguf"
      }

      refute Model.downloaded?(model)
    end

    test "returns true when file exists" do
      path = Path.join(System.tmp_dir(), "candil_test_model_#{:rand.uniform(9999)}.gguf")
      File.write!(path, "fake model")

      model = %Model{
        alias: :test,
        type: :local,
        model_dir: Path.dirname(path),
        filename: Path.basename(path)
      }

      try do
        assert Model.downloaded?(model) == true
      after
        File.rm!(path)
      end
    end
  end

  describe "validate/1" do
    test "returns :ok for valid local model" do
      model = %Model{
        alias: :llama3,
        type: :local,
        model_dir: "/models",
        filename: "llama-3-8b-q4.gguf",
        engine: :llama_server
      }

      assert Model.validate(model) == :ok
    end

    test "returns :ok for valid remote model" do
      model = %Model{
        alias: :gpt4o,
        type: :remote,
        name: "gpt-4o",
        provider: :openai
      }

      assert Model.validate(model) == :ok
    end

    test "returns error for missing alias" do
      model = %Model{alias: nil, type: :local}
      assert {:error, errors} = Model.validate(model)
      assert "alias is required" in errors
    end

    test "returns error for local model without engine" do
      model = %Model{
        alias: :llama3,
        type: :local,
        model_dir: "/models",
        filename: "model.gguf",
        engine: nil
      }

      assert {:error, errors} = Model.validate(model)
      assert "engine is required for local models" in errors
    end

    test "returns error for local model without model_dir" do
      model = %Model{
        alias: :llama3,
        type: :local,
        model_dir: nil,
        filename: "model.gguf",
        engine: :llama_server
      }

      assert {:error, errors} = Model.validate(model)
      assert "model_dir is required for local models" in errors
    end

    test "returns error for local model without filename" do
      model = %Model{
        alias: :llama3,
        type: :local,
        model_dir: "/models",
        filename: nil,
        engine: :llama_server
      }

      assert {:error, errors} = Model.validate(model)
      assert "filename is required for local models" in errors
    end

    test "returns error for remote model without provider" do
      model = %Model{
        alias: :gpt4o,
        type: :remote,
        name: "gpt-4o",
        provider: nil
      }

      assert {:error, errors} = Model.validate(model)
      assert "provider is required for remote models" in errors
    end

    test "returns error for remote model without name" do
      model = %Model{
        alias: :gpt4o,
        type: :remote,
        name: nil,
        provider: :openai
      }

      assert {:error, errors} = Model.validate(model)
      assert "name is required for remote models" in errors
    end

    test "returns error for unknown type" do
      model = %Model{alias: :test, type: :unknown}
      assert {:error, errors} = Model.validate(model)
      assert "unknown type: unknown" in errors
    end

    test "returns error for invalid usage types" do
      model = %Model{
        alias: :test,
        type: :local,
        usage: [:chat, :invalid_usage]
      }

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "invalid usage types"))
    end

    test "returns error when usage is not a list" do
      model = %Model{alias: :test, type: :local, usage: "not a list"}
      assert {:error, errors} = Model.validate(model)
      assert "usage must be a list" in errors
    end
  end
end
