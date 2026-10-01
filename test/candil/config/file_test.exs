defmodule Candil.Config.FileTest do
  use ExUnit.Case, async: false

  alias Candil.Config.File, as: ConfigFile

  doctest Candil.Config.File

  @real_toml """
  [general]
  data_dir = "~/.candil"

  [engine.llama_cpp]
  binary = "llama-server"
  base_port = 10000

  [engine.llama_cpp.install]
  strategy = "source"
  repo = "https://github.com/ggml-org/llama.cpp"
  dir = "~/.candil/llm/bin"
  binaries = ["llama-server", "llama-cli"]
  cmake_args = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_CUDA_ARCHITECTURES=120a"]

  [engine.llama_cpp.auth]
  api_key_env = "LLAMA_API_KEY"

  [model.coder]
  type = "local"
  engine = "llama_cpp"
  context_size = 131072
  port = 9999
  model_args = ["--n-gpu-layers", "-1", "--n-cpu-moe", "30", "--jinja"]

  [model.coder.source]
  kind = "huggingface"
  repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
  file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
  dest = "~/.candil/models"

  [model.gpt4o]
  type = "remote"
  name = "gpt-4o"
  provider = "openai"

  [provider.openai]
  type = "openai"
  base_url = "https://api.openai.com"
  api_key = { env = "OPENAI_API_KEY" }

  [consumer.posadero]
  model_default = "coder"
  """

  describe "default_path/0" do
    test "is a .toml under the config dir by default" do
      assert ConfigFile.default_path() =~ ".toml"
    end

    test "honours CANDIL_CONFIG" do
      original = System.get_env("CANDIL_CONFIG")
      System.put_env("CANDIL_CONFIG", "/tmp/candil-test.toml")

      on_exit(fn ->
        if original,
          do: System.put_env("CANDIL_CONFIG", original),
          else: System.delete_env("CANDIL_CONFIG")
      end)

      assert ConfigFile.default_path() == "/tmp/candil-test.toml"
    end

    test "expands the default rather than leaving a literal tilde" do
      original = System.get_env("CANDIL_CONFIG")
      System.delete_env("CANDIL_CONFIG")
      on_exit(fn -> if original, do: System.put_env("CANDIL_CONFIG", original) end)

      refute String.contains?(ConfigFile.default_path(), "~")
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "a missing file is not an error", %{tmp_dir: dir} do
      assert {:ok, %{}} = ConfigFile.load(Path.join(dir, "nope.toml"))
    end

    @tag :tmp_dir
    test "an empty file is not an error", %{tmp_dir: dir} do
      path = Path.join(dir, "empty.toml")
      File.write!(path, "")
      assert {:ok, %{}} = ConfigFile.load(path)
    end

    @tag :tmp_dir
    test "parses and validates a realistic file", %{tmp_dir: dir} do
      path = Path.join(dir, "candil.toml")
      File.write!(path, @real_toml)

      assert {:ok, config} = ConfigFile.load(path)

      assert config["general"]["data_dir"] == "~/.candil"
      assert config["engine"]["llama_cpp"]["binary"] == "llama-server"

      install = config["engine"]["llama_cpp"]["install"]
      assert install["strategy"] == "source"

      assert install["cmake_args"] == [
               "-DCMAKE_BUILD_TYPE=Release",
               "-DCMAKE_CUDA_ARCHITECTURES=120a"
             ]

      assert config["engine"]["llama_cpp"]["auth"]["api_key_env"] == "LLAMA_API_KEY"

      model = config["model"]["coder"]
      assert model["port"] == 9999
      assert model["context_size"] == 131_072
      assert config["model"]["coder"]["source"]["repo"] =~ "Qwen3-Coder"

      assert config["provider"]["openai"]["api_key"] == %{"env" => "OPENAI_API_KEY"}
      assert config["consumer"]["posadero"]["model_default"] == "coder"
    end

    @tag :tmp_dir
    test "model_args survives as an ordered list", %{tmp_dir: dir} do
      path = Path.join(dir, "candil.toml")
      File.write!(path, @real_toml)

      {:ok, config} = ConfigFile.load(path)
      args = config["model"]["coder"]["model_args"]

      # Order is behaviour: llama-server takes the last occurrence of a
      # repeated flag. A round trip through a map would lose it silently.
      assert args == ["--n-gpu-layers", "-1", "--n-cpu-moe", "30", "--jinja"]
    end

    @tag :tmp_dir
    test "reports which file is broken", %{tmp_dir: dir} do
      path = Path.join(dir, "broken.toml")
      File.write!(path, "[model.coder\ntype = ")

      assert {:error, {:invalid, message}} = ConfigFile.load(path)
      assert message =~ path
    end

    @tag :tmp_dir
    test "returns schema problems as a list", %{tmp_dir: dir} do
      path = Path.join(dir, "invalid.toml")

      File.write!(path, """
      [model.coder]
      type = "hologram"
      """)

      assert {:error, problems} = ConfigFile.load(path)
      assert Enum.any?(problems, &String.contains?(&1, "coder"))
    end
  end

  describe "expand/1" do
    test "expands tildes in paths so nothing carries a literal tilde" do
      config = %{
        "engine" => %{
          "llama" => %{"install" => %{"strategy" => "source", "dir" => "~/.candil/llm"}}
        },
        "model" => %{"coder" => %{"source" => %{"dest" => "~/.candil/models"}}},
        "general" => %{"data_dir" => "~/.candil"}
      }

      expanded = ConfigFile.expand(config)

      install_dir = expanded["engine"]["llama"]["install"]["dir"]
      refute String.contains?(install_dir, "~")
      assert String.starts_with?(install_dir, "/")

      refute String.contains?(expanded["model"]["coder"]["source"]["dest"], "~")
      refute String.contains?(expanded["general"]["data_dir"], "~")
    end

    test "leaves a base_url alone, because it is not a filesystem path" do
      config = %{
        "model" => %{"gpt4o" => %{"type" => "remote", "base_url" => "https://api.openai.com"}}
      }

      assert ConfigFile.expand(config)["model"]["gpt4o"]["base_url"] == "https://api.openai.com"
    end

    test "expands the draft source too, which is where the absolute path matters" do
      config = %{
        "model" => %{
          "analyst" => %{"draft" => %{"kind" => "huggingface", "dest" => "~/.candil/models"}}
        }
      }

      dest = ConfigFile.expand(config)["model"]["analyst"]["draft"]["dest"]
      refute String.contains?(dest, "~")
    end

    test "does not modify the input" do
      config = %{"general" => %{"data_dir" => "~/.candil"}}
      ConfigFile.expand(config)
      assert config["general"]["data_dir"] == "~/.candil"
    end
  end

  describe "save/2" do
    test "refuses to write an invalid document" do
      assert {:error, problems} = ConfigFile.save(%{"model" => %{"m" => %{}}}, "/tmp/x.toml")
      assert Enum.any?(problems, &String.contains?(&1, "type is required"))
    end

    test "reports that writing is not implemented yet" do
      assert {:error, %Candil.Error{reason: :not_implemented}} =
               ConfigFile.save(%{"general" => %{"data_dir" => "/tmp"}}, "/tmp/x.toml")
    end
  end
end
