defmodule Candil.ModelV4Test do
  use ExUnit.Case, async: true

  alias Candil.Model
  alias Candil.Source

  describe "type :external" do
    test "needs a base_url and an engine, and nothing else" do
      # An external model is a server somebody else runs. Candil talks HTTP to
      # it and never spawns a process, so there is no binary, no model file
      # and no port to bind.
      assert {:error, reasons} =
               Model.validate(%Model{alias: :tgi, type: :external, engine: :box})

      assert "base_url is required for external models" in reasons
      refute Enum.any?(reasons, &(&1 =~ "launcher"))
    end

    test "an external model without an engine says so" do
      assert {:error, reasons} =
               Model.validate(%Model{alias: :tgi, type: :external, base_url: "http://x"})

      assert "engine is required for external models" in reasons
    end

    test "a model has no launcher field: that lives in the engine" do
      # `Engine.launch/3` reads `engine.launcher`. Nothing ever read
      # `model.launcher`, the config could not set it, and validation demanded
      # it — so an external model could not be declared in a TOML at all.
      model_keys = %Model{alias: :m, type: :local} |> Map.from_struct() |> Map.keys()
      engine_keys = %Candil.Engine{alias: :e} |> Map.from_struct() |> Map.keys()

      refute :launcher in model_keys
      assert :launcher in engine_keys
    end

    test "validates once both are present" do
      assert :ok =
               Model.validate(%Model{
                 alias: :tgi,
                 type: :external,
                 engine: :box,
                 base_url: "http://10.0.0.5:8080",
                 context_size: 32_768
               })
    end

    test "is not managed by Candil" do
      external = %Model{alias: :tgi, type: :external}
      remote = %Model{alias: :gpt4o, type: :remote}
      local = %Model{alias: :coder, type: :local}

      refute Model.managed?(external)
      refute Model.managed?(remote)
      assert Model.managed?(local)
    end

    test "has no local file path" do
      external = %Model{alias: :tgi, type: :external, engine: :box, base_url: "http://x"}
      assert Model.file_path(external) == nil
    end
  end

  describe "port belongs to the model" do
    test "defaults to :auto" do
      assert %Model{alias: :m, type: :local}.port == :auto
    end

    test "can be pinned, which is what a per-model port is for" do
      assert %Model{alias: :embed, type: :local, port: 9990}.port == 9990
    end
  end

  describe "file_path/1 derived from a source" do
    test "uses a huggingface source's dest and file" do
      model = %Model{
        alias: :coder,
        type: :local,
        engine: :llama_cpp,
        source: %Source{
          kind: :huggingface,
          repo: "u/r",
          file: "model.gguf",
          dest: "/models"
        }
      }

      assert Model.file_path(model) == "/models/model.gguf"
      assert Model.validate(model) == :ok
    end

    test "honours dest_name, which is how a repo subdirectory gets flattened" do
      model = %Model{
        alias: :analyst,
        type: :local,
        engine: :llama_cpp,
        source: %Source{
          kind: :huggingface,
          repo: "u/r",
          file: "MTP/mtp-Q4_0.gguf",
          dest: "/models",
          dest_name: "mtp-Q4_0.gguf"
        }
      }

      assert Model.file_path(model) == "/models/mtp-Q4_0.gguf"
    end

    test "prefers explicit model_dir and filename over the source" do
      model = %Model{
        alias: :coder,
        type: :local,
        engine: :llama_cpp,
        model_dir: "/explicit",
        filename: "m.gguf",
        source: %Source{kind: :huggingface, repo: "u/r", file: "other.gguf", dest: "/derived"}
      }

      assert Model.file_path(model) == "/explicit/m.gguf"
    end

    test "a local source is its own path" do
      model = %Model{
        alias: :coder,
        type: :local,
        engine: :llama_cpp,
        source: %Source{kind: :local, path: "/somewhere/m.gguf"}
      }

      assert Model.file_path(model) == "/somewhere/m.gguf"
    end
  end

  describe "validation never raises" do
    test "rejects path traversal with a message naming the problem" do
      assert {:error, reasons} =
               Model.validate(%Model{
                 alias: :bad,
                 type: :local,
                 engine: :llama,
                 model_dir: "../../etc",
                 filename: "m.gguf"
               })

      assert Enum.any?(reasons, &String.contains?(&1, "path traversal"))
    end

    test "rejects a source whose destination escapes" do
      assert {:error, reasons} =
               Model.validate(%Model{
                 alias: :bad,
                 type: :local,
                 engine: :llama,
                 source: %Source{
                   kind: :huggingface,
                   repo: "u/r",
                   file: "m.gguf",
                   dest: "/models",
                   dest_name: "../../../etc/passwd"
                 }
               })

      assert Enum.any?(reasons, &String.contains?(&1, "path traversal"))
    end

    test "a local model with no path at all is rejected, not crashed on" do
      assert {:error, reasons} =
               Model.validate(%Model{alias: :bad, type: :local, engine: :llama})

      assert "model_dir/filename or source is required for local models" in reasons
    end
  end
end
