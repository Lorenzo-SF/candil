defmodule Candil.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Candil.Config.Schema

  doctest Candil.Config.Schema

  describe "top level" do
    test "accepts an empty document" do
      assert {:ok, %{}} = Schema.validate(%{})
    end

    test "rejects a section that is not a table" do
      assert {:error, problems} = Schema.validate(%{"engine" => "nope"})
      assert Enum.any?(problems, &String.contains?(&1, "engine must be a table"))
    end

    test "reports every problem, not just the first" do
      # Someone fixing a config file should see all of it in one pass.
      config = %{
        "engine" => %{"llama" => %{"install" => %{"strategy" => "source"}}},
        "model" => %{"coder" => %{"type" => "local", "model_args" => %{"a" => "b"}}}
      }

      assert {:error, problems} = Schema.validate(config)
      assert length(problems) >= 3
    end
  end

  describe "[engine]" do
    test "accepts a precompiled plan" do
      config = %{
        "engine" => %{
          "llama_cpp" => %{
            "binary" => "llama-server",
            "install" => %{"strategy" => "precompiled", "dir" => "/opt/llm"}
          }
        }
      }

      assert {:ok, ^config} = Schema.validate(config)
    end

    test "accepts a source plan with cmake_args" do
      config = %{
        "engine" => %{
          "llama_cpp" => %{
            "binary" => "/opt/llm/llama-server",
            "install" => %{
              "strategy" => "source",
              "repo" => "https://github.com/ggml-org/llama.cpp",
              "dir" => "/opt/llm",
              "binaries" => ["llama-server"],
              "cmake_args" => ["-DCMAKE_CUDA_ARCHITECTURES=120a"]
            }
          }
        }
      }

      assert {:ok, ^config} = Schema.validate(config)
    end

    test "rejects an empty binaries list for a source plan" do
      config = %{
        "engine" => %{
          "e" => %{
            "install" => %{
              "strategy" => "source",
              "repo" => "r",
              "dir" => "/d",
              "binaries" => []
            }
          }
        }
      }

      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "binaries must not be empty"))
    end

    test "rejects a source plan with no repo" do
      config = %{"engine" => %{"e" => %{"install" => %{"strategy" => "source", "dir" => "/d"}}}}
      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "repo is required"))
    end

    test "rejects a precompiled plan with no dir" do
      config = %{"engine" => %{"e" => %{"install" => %{"strategy" => "precompiled"}}}}
      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "dir is required"))
    end

    test "never inspects what is in cmake_args" do
      # The :source strategy exists precisely because Candil cannot know the
      # right flags. Validation checks the shape and stops.
      config = %{
        "engine" => %{
          "e" => %{
            "install" => %{
              "strategy" => "source",
              "repo" => "r",
              "dir" => "/d",
              "binaries" => ["llama-server"],
              "cmake_args" => ["-DWHATEVER=ON", "-DNOT_A_REAL_FLAG=1", "-DGGML_TOTALLY_FAKE=1"]
            }
          }
        }
      }

      assert {:ok, ^config} = Schema.validate(config)
    end

    test "rejects cmake_args that is not a list of strings" do
      config = %{
        "engine" => %{
          "e" => %{
            "install" => %{
              "strategy" => "source",
              "repo" => "r",
              "dir" => "/d",
              "binaries" => ["llama-server"],
              "cmake_args" => [1, 2]
            }
          }
        }
      }

      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "cmake_args must be a list of strings"))
    end

    test "accepts an auth table" do
      config = %{"engine" => %{"e" => %{"auth" => %{"api_key_env" => "LLAMA_API_KEY"}}}}
      assert {:ok, ^config} = Schema.validate(config)
    end
  end

  describe "[model]" do
    defp model(extra) do
      %{"model" => %{"coder" => Map.merge(%{"type" => "local"}, extra)}}
    end

    test "requires a type" do
      assert {:error, problems} = Schema.validate(%{"model" => %{"coder" => %{}}})
      assert Enum.any?(problems, &String.contains?(&1, "type is required"))
    end

    test "rejects an unknown type" do
      assert {:error, problems} = Schema.validate(model(%{"type" => "hologram"}))
      assert Enum.any?(problems, &String.contains?(&1, "must be local, remote or external"))
    end

    test "accepts auto and integer ports" do
      assert {:ok, _} = Schema.validate(model(%{"type" => "local", "port" => "auto"}))
      assert {:ok, _} = Schema.validate(model(%{"type" => "local", "port" => 9999}))
    end

    test "rejects a nonsense port" do
      assert {:error, problems} = Schema.validate(model(%{"type" => "local", "port" => "nueve"}))
      assert Enum.any?(problems, &String.contains?(&1, "port must be"))
    end

    test "rejects a 99999 port" do
      assert {:error, problems} = Schema.validate(model(%{"type" => "local", "port" => 99_999}))
      assert Enum.any?(problems, &String.contains?(&1, "port must be"))
    end

    test "accepts model_args as an ordered list" do
      config = model(%{"type" => "local", "model_args" => ["--jinja", "--temp", "0.7"]})
      assert {:ok, ^config} = Schema.validate(config)
    end

    test "rejects model_args as a table, and says why" do
      # The reason matters enough to be in the error message: llama-server
      # takes the last occurrence of a repeated flag, so a TOML map would
      # silently lose the ordering that --cpu depends on.
      config = model(%{"type" => "local", "model_args" => %{"temp" => "0.7"}})
      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "ordered list"))
      assert Enum.any?(problems, &String.contains?(&1, "last occurrence"))
    end
  end

  describe "[model.source]" do
    test "huggingface needs a repo and a file" do
      config = %{
        "model" => %{
          "m" => %{"type" => "local", "source" => %{"kind" => "huggingface"}}
        }
      }

      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "repo is required"))
      assert Enum.any?(problems, &String.contains?(&1, "file is required"))
    end

    test "url needs a url" do
      config = %{
        "model" => %{"m" => %{"type" => "local", "source" => %{"kind" => "url"}}}
      }

      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "url is required"))
    end

    test "local needs a path" do
      config = %{
        "model" => %{"m" => %{"type" => "local", "source" => %{"kind" => "local"}}}
      }

      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "path is required"))
    end

    test "a full huggingface source is fine" do
      config = %{
        "model" => %{
          "coder" => %{
            "type" => "local",
            "source" => %{
              "kind" => "huggingface",
              "repo" => "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
              "file" => "model.gguf",
              "dest" => "/models"
            }
          }
        }
      }

      assert {:ok, ^config} = Schema.validate(config)
    end
  end

  describe "[provider]" do
    test "needs a type and a base_url" do
      assert {:error, problems} = Schema.validate(%{"provider" => %{"openai" => %{}}})
      assert Enum.any?(problems, &String.contains?(&1, "type is required"))
      assert Enum.any?(problems, &String.contains?(&1, "base_url is required"))
    end

    test "accepts a string key and an env table" do
      string = %{
        "provider" => %{"p" => %{"type" => "openai", "base_url" => "u", "api_key" => "sk"}}
      }

      env = %{
        "provider" => %{
          "p" => %{"type" => "openai", "base_url" => "u", "api_key" => %{"env" => "K"}}
        }
      }

      assert {:ok, _} = Schema.validate(string)
      assert {:ok, _} = Schema.validate(env)
    end

    test "rejects an api_key that is neither" do
      config = %{
        "provider" => %{"p" => %{"type" => "openai", "base_url" => "u", "api_key" => 42}}
      }

      assert {:error, problems} = Schema.validate(config)
      assert Enum.any?(problems, &String.contains?(&1, "api_key must be a string"))
    end
  end

  describe "[consumer]" do
    test "needs a model_default" do
      assert {:error, problems} = Schema.validate(%{"consumer" => %{"posadero" => %{}}})
      assert Enum.any?(problems, &String.contains?(&1, "model_default is required"))
    end

    test "accepts one with a default" do
      config = %{"consumer" => %{"posadero" => %{"model_default" => "embed"}}}
      assert {:ok, ^config} = Schema.validate(config)
    end
  end

  describe "[general]" do
    test "paths must be strings" do
      assert {:error, problems} = Schema.validate(%{"general" => %{"data_dir" => 1}})
      assert Enum.any?(problems, &String.contains?(&1, "general.data_dir must be a string"))
    end

    test "accepts the documented shape" do
      config = %{
        "general" => %{
          "data_dir" => "~/.candil",
          "log_dir" => "~/.candil/logs",
          "default_consumer" => "default"
        }
      }

      assert {:ok, ^config} = Schema.validate(config)
    end
  end
end
