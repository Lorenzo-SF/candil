defmodule Candil.StoreTest do
  use ExUnit.Case, async: true

  alias Candil.{Engine, Model, Provider, Store}

  setup do
    # Clean up tables before each test
    :ets.delete_all_objects(:candil_llm_engines)
    :ets.delete_all_objects(:candil_llm_models)
    :ets.delete_all_objects(:candil_llm_providers)
    :ok
  end

  describe "register_engine/1" do
    test "registers an engine and returns :ok" do
      engine = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080}
      assert Store.register_engine(engine) == :ok
    end

    test "overwrites existing engine with same alias" do
      engine1 = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080, start_args: ["--a"]}
      engine2 = %Engine{alias: :test_engine, host: "127.0.0.2", port: 9090, start_args: ["--b"]}

      Store.register_engine(engine1)
      Store.register_engine(engine2)

      assert {:ok, retrieved} = Store.get_engine(:test_engine)
      assert retrieved.host == "127.0.0.2"
      assert retrieved.port == 9090
      assert retrieved.start_args == ["--b"]
    end
  end

  describe "register_model/1 validation" do
    test "refuses a model that could never start" do
      # Model.validate/1 existed for the whole 3.x line and nothing called it,
      # so every malformed model was accepted and only discovered when the
      # engine refused to launch.
      model = %Model{alias: :broken, type: :local, engine: :e}
      assert {:error, reasons} = Store.register_model(model)
      assert "model_dir/filename or source is required for local models" in reasons
      assert Store.get_model(:broken) == {:error, :not_found}
    end

    test "refuses a remote model with no provider" do
      model = %Model{alias: :broken_remote, type: :remote, name: "gpt-4"}
      assert {:error, reasons} = Store.register_model(model)
      assert "provider is required for remote models" in reasons
    end
  end

  describe "register_engine/1 validation" do
    test "refuses an engine whose install plan is incomplete" do
      engine = %Engine{
        alias: :broken_engine,
        install: %Candil.Build{strategy: :source, dir: "/opt/llm"}
      }

      assert {:error, reasons} = Store.register_engine(engine)
      assert "repo is required" in reasons
      assert "binaries is required" in reasons
      assert Store.get_engine(:broken_engine) == {:error, :not_found}
    end

    test "accepts an engine with no install plan at all" do
      assert Store.register_engine(%Engine{alias: :plain}) == :ok
    end
  end

  describe "register_model/1" do
    test "registers a model and returns :ok" do
      model = %Model{
        alias: :test_model,
        type: :local,
        engine: :test_engine,
        model_dir: "/models",
        filename: "test.gguf"
      }

      assert Store.register_model(model) == :ok
    end
  end

  describe "register_provider/1" do
    test "registers a provider and returns :ok" do
      provider = %Provider{alias: :test_provider, type: :openai, base_url: "https://api.test.com"}
      assert Store.register_provider(provider) == :ok
    end
  end

  describe "get_engine/1" do
    test "returns {:ok, engine} when engine exists" do
      engine = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080}
      Store.register_engine(engine)

      assert Store.get_engine(:test_engine) == {:ok, engine}
    end

    test "returns {:error, :not_found} when engine does not exist" do
      assert Store.get_engine(:nonexistent) == {:error, :not_found}
    end
  end

  describe "get_model/1" do
    test "returns {:ok, model} when model exists" do
      model = %Model{
        alias: :test_model,
        type: :local,
        engine: :test_engine,
        model_dir: "/models",
        filename: "test.gguf"
      }

      Store.register_model(model)

      assert Store.get_model(:test_model) == {:ok, model}
    end

    test "returns {:error, :not_found} when model does not exist" do
      assert Store.get_model(:nonexistent) == {:error, :not_found}
    end
  end

  describe "get_provider/1" do
    test "returns {:ok, provider} when provider exists with {:system, env_var} api_key" do
      System.put_env("TEST_PROVIDER_KEY", "sk-test123")

      provider = %Provider{
        alias: :test_provider,
        type: :openai,
        base_url: "https://api.test.com",
        api_key: {:system, "TEST_PROVIDER_KEY"}
      }

      Store.register_provider(provider)
      assert {:ok, retrieved} = Store.get_provider(:test_provider)
      assert retrieved.api_key == "sk-test123"
    end

    test "resolves {:system, ENV_VAR} api_key from environment" do
      System.put_env("TEST_API_KEY", "env-secret-key")

      provider = %Provider{
        alias: :test_provider,
        type: :openai,
        base_url: "https://api.test.com",
        api_key: {:system, "TEST_API_KEY"}
      }

      Store.register_provider(provider)
      assert {:ok, retrieved} = Store.get_provider(:test_provider)
      assert retrieved.api_key == "env-secret-key"

      System.delete_env("TEST_API_KEY")
    end

    test "returns {:error, :not_found} when provider does not exist" do
      assert Store.get_provider(:nonexistent) == {:error, :not_found}
    end
  end

  describe "list_engines/0" do
    test "returns empty list when no engines registered" do
      assert Store.list_engines() == []
    end

    test "returns all registered engines" do
      engine1 = %Engine{alias: :engine1, host: "127.0.0.1", port: 8080}
      engine2 = %Engine{alias: :engine2, host: "127.0.0.2", port: 9090}
      Store.register_engine(engine1)
      Store.register_engine(engine2)

      engines = Store.list_engines()
      assert length(engines) == 2
      assert Enum.any?(engines, &(&1.alias == :engine1))
      assert Enum.any?(engines, &(&1.alias == :engine2))
    end
  end

  describe "list_models/0" do
    test "returns empty list when no models registered" do
      assert Store.list_models() == []
    end

    test "returns all registered models" do
      model1 = %Model{
        alias: :model1,
        type: :local,
        engine: :e1,
        model_dir: "/models",
        filename: "m1.gguf"
      }

      model2 = %Model{alias: :model2, type: :remote, name: "gpt-4", provider: :p1}
      Store.register_model(model1)
      Store.register_model(model2)

      models = Store.list_models()
      assert length(models) == 2
    end
  end

  describe "list_providers/0" do
    test "returns empty list when no providers registered" do
      assert Store.list_providers() == []
    end

    test "returns all registered providers" do
      provider1 = %Provider{alias: :p1, type: :openai, base_url: "https://api.test1.com"}
      provider2 = %Provider{alias: :p2, type: :anthropic, base_url: "https://api.test2.com"}
      Store.register_provider(provider1)
      Store.register_provider(provider2)

      providers = Store.list_providers()
      assert length(providers) == 2
    end
  end

  describe "deregister_engine/1" do
    test "removes engine and returns :ok" do
      engine = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080}
      Store.register_engine(engine)
      assert Store.get_engine(:test_engine) == {:ok, engine}

      assert Store.deregister_engine(:test_engine) == :ok
      assert Store.get_engine(:test_engine) == {:error, :not_found}
    end

    test "returns :ok even if engine does not exist" do
      assert Store.deregister_engine(:nonexistent) == :ok
    end
  end

  describe "deregister_model/1" do
    test "removes model and returns :ok" do
      model = %Model{alias: :test_model, type: :local, engine: :e1}
      Store.register_model(model)

      assert Store.deregister_model(:test_model) == :ok
      assert Store.get_model(:test_model) == {:error, :not_found}
    end
  end

  describe "deregister_provider/1" do
    test "removes provider and returns :ok" do
      provider = %Provider{alias: :test_provider, type: :openai, base_url: "https://api.test.com"}
      Store.register_provider(provider)

      assert Store.deregister_provider(:test_provider) == :ok
      assert Store.get_provider(:test_provider) == {:error, :not_found}
    end
  end
end
