defmodule Candil.ConfigTest do
  use ExUnit.Case, async: true

  alias Candil.Config
  alias Candil.{Engine, Model, Provider}

  setup do
    # Clean up tables before each test
    :ets.delete_all_objects(:apero_llm_engines)
    :ets.delete_all_objects(:apero_llm_models)
    :ets.delete_all_objects(:apero_llm_providers)
    :ok
  end

  describe "register_engine/1" do
    test "registers an engine and returns :ok" do
      engine = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080}
      assert Config.register_engine(engine) == :ok
    end

    test "overwrites existing engine with same alias" do
      engine1 = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080, start_args: ["--a"]}
      engine2 = %Engine{alias: :test_engine, host: "127.0.0.2", port: 9090, start_args: ["--b"]}

      Config.register_engine(engine1)
      Config.register_engine(engine2)

      assert {:ok, retrieved} = Config.get_engine(:test_engine)
      assert retrieved.host == "127.0.0.2"
      assert retrieved.port == 9090
      assert retrieved.start_args == ["--b"]
    end
  end

  describe "register_model/1" do
    test "registers a model and returns :ok" do
      model = %Model{alias: :test_model, type: :local, engine: :test_engine}
      assert Config.register_model(model) == :ok
    end
  end

  describe "register_provider/1" do
    test "registers a provider and returns :ok" do
      provider = %Provider{alias: :test_provider, type: :openai, base_url: "https://api.test.com"}
      assert Config.register_provider(provider) == :ok
    end
  end

  describe "get_engine/1" do
    test "returns {:ok, engine} when engine exists" do
      engine = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080}
      Config.register_engine(engine)

      assert Config.get_engine(:test_engine) == {:ok, engine}
    end

    test "returns {:error, :not_found} when engine does not exist" do
      assert Config.get_engine(:nonexistent) == {:error, :not_found}
    end
  end

  describe "get_model/1" do
    test "returns {:ok, model} when model exists" do
      model = %Model{alias: :test_model, type: :local, engine: :test_engine}
      Config.register_model(model)

      assert Config.get_model(:test_model) == {:ok, model}
    end

    test "returns {:error, :not_found} when model does not exist" do
      assert Config.get_model(:nonexistent) == {:error, :not_found}
    end
  end

  describe "get_provider/1" do
    test "returns {:ok, provider} when provider exists with plain api_key" do
      provider = %Provider{
        alias: :test_provider,
        type: :openai,
        base_url: "https://api.test.com",
        api_key: "sk-test123"
      }

      Config.register_provider(provider)
      assert {:ok, retrieved} = Config.get_provider(:test_provider)
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

      Config.register_provider(provider)
      assert {:ok, retrieved} = Config.get_provider(:test_provider)
      assert retrieved.api_key == "env-secret-key"

      System.delete_env("TEST_API_KEY")
    end

    test "returns {:error, :not_found} when provider does not exist" do
      assert Config.get_provider(:nonexistent) == {:error, :not_found}
    end
  end

  describe "list_engines/0" do
    test "returns empty list when no engines registered" do
      assert Config.list_engines() == []
    end

    test "returns all registered engines" do
      engine1 = %Engine{alias: :engine1, host: "127.0.0.1", port: 8080}
      engine2 = %Engine{alias: :engine2, host: "127.0.0.2", port: 9090}
      Config.register_engine(engine1)
      Config.register_engine(engine2)

      engines = Config.list_engines()
      assert length(engines) == 2
      assert Enum.any?(engines, &(&1.alias == :engine1))
      assert Enum.any?(engines, &(&1.alias == :engine2))
    end
  end

  describe "list_models/0" do
    test "returns empty list when no models registered" do
      assert Config.list_models() == []
    end

    test "returns all registered models" do
      model1 = %Model{alias: :model1, type: :local, engine: :e1}
      model2 = %Model{alias: :model2, type: :remote, name: "gpt-4", provider: :p1}
      Config.register_model(model1)
      Config.register_model(model2)

      models = Config.list_models()
      assert length(models) == 2
    end
  end

  describe "list_providers/0" do
    test "returns empty list when no providers registered" do
      assert Config.list_providers() == []
    end

    test "returns all registered providers" do
      provider1 = %Provider{alias: :p1, type: :openai, base_url: "https://api.test1.com"}
      provider2 = %Provider{alias: :p2, type: :anthropic, base_url: "https://api.test2.com"}
      Config.register_provider(provider1)
      Config.register_provider(provider2)

      providers = Config.list_providers()
      assert length(providers) == 2
    end
  end

  describe "deregister_engine/1" do
    test "removes engine and returns :ok" do
      engine = %Engine{alias: :test_engine, host: "127.0.0.1", port: 8080}
      Config.register_engine(engine)
      assert Config.get_engine(:test_engine) == {:ok, engine}

      assert Config.deregister_engine(:test_engine) == :ok
      assert Config.get_engine(:test_engine) == {:error, :not_found}
    end

    test "returns :ok even if engine does not exist" do
      assert Config.deregister_engine(:nonexistent) == :ok
    end
  end

  describe "deregister_model/1" do
    test "removes model and returns :ok" do
      model = %Model{alias: :test_model, type: :local, engine: :e1}
      Config.register_model(model)

      assert Config.deregister_model(:test_model) == :ok
      assert Config.get_model(:test_model) == {:error, :not_found}
    end
  end

  describe "deregister_provider/1" do
    test "removes provider and returns :ok" do
      provider = %Provider{alias: :test_provider, type: :openai, base_url: "https://api.test.com"}
      Config.register_provider(provider)

      assert Config.deregister_provider(:test_provider) == :ok
      assert Config.get_provider(:test_provider) == {:error, :not_found}
    end
  end
end
