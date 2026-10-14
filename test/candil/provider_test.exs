defmodule Candil.ProviderTest do
  use ExUnit.Case, async: true

  alias Candil.Provider

  describe "provider_types/0" do
    test "returns all valid provider types" do
      types = Provider.provider_types()
      assert :openai in types
      assert :anthropic in types
      assert :ollama in types
      assert :openai_compatible in types
    end
  end

  describe "validate/1" do
    test "returns :ok for valid openai provider" do
      provider = %Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: "sk-test"
      }

      assert Provider.validate(provider) == :ok
    end

    test "returns :ok for valid anthropic provider" do
      provider = %Provider{
        alias: :anthropic,
        type: :anthropic,
        base_url: "https://api.anthropic.com",
        api_key: "sk-ant-test"
      }

      assert Provider.validate(provider) == :ok
    end

    test "returns :ok for valid ollama provider" do
      provider = %Provider{
        alias: :ollama,
        type: :ollama,
        base_url: "http://localhost:11434"
      }

      assert Provider.validate(provider) == :ok
    end

    test "returns :ok for valid openai_compatible provider" do
      provider = %Provider{
        alias: :groq,
        type: :openai_compatible,
        base_url: "https://api.groq.com/openai",
        api_key: "gsk_test"
      }

      assert Provider.validate(provider) == :ok
    end

    test "returns error for missing alias" do
      provider = %Provider{
        alias: nil,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: "sk-test"
      }

      assert {:error, errors} = Provider.validate(provider)
      assert "alias is required" in errors
    end

    test "returns error for missing base_url" do
      provider = %Provider{
        alias: :test,
        type: :openai,
        base_url: nil,
        api_key: "sk-test"
      }

      assert {:error, errors} = Provider.validate(provider)
      assert "base_url is required" in errors
    end

    test "returns error for unknown type" do
      provider = %Provider{
        alias: :test,
        type: :unknown,
        base_url: "https://api.test.com"
      }

      assert {:error, errors} = Provider.validate(provider)
      assert "unknown type: unknown" in errors
    end

    test "returns error for openai without api_key" do
      provider = %Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: nil
      }

      assert {:error, errors} = Provider.validate(provider)
      assert "api_key is required for openai" in errors
    end

    test "returns error for anthropic without api_key" do
      provider = %Provider{
        alias: :anthropic,
        type: :anthropic,
        base_url: "https://api.anthropic.com",
        api_key: nil
      }

      assert {:error, errors} = Provider.validate(provider)
      assert "api_key is required for anthropic" in errors
    end

    test "does not require api_key for ollama" do
      provider = %Provider{
        alias: :ollama,
        type: :ollama,
        base_url: "http://localhost:11434",
        api_key: nil
      }

      assert Provider.validate(provider) == :ok
    end

    test "does not require api_key for openai_compatible" do
      provider = %Provider{
        alias: :local,
        type: :openai_compatible,
        base_url: "http://localhost:8080",
        api_key: nil
      }

      assert Provider.validate(provider) == :ok
    end
  end

  describe "auth_headers/1 con la clave en el entorno" do
    # El fallo: `Hydrate` deja `api_key: {:system, "VAR"}` —una tupla— y las
    # guardas de `auth_headers/1` pedian `is_binary(key)`. Una tupla no pasaba
    # por ninguna, asi que la peticion salia **sin cabecera de autorizacion**:
    # un 401 sin explicacion contra el proveedor que el usuario habia
    # configurado bien. Medido el 2026-10-14.
    setup do
      System.put_env("CANDIL_TEST_PROVIDER_KEY", "sk-del-entorno")
      on_exit(fn -> System.delete_env("CANDIL_TEST_PROVIDER_KEY") end)
      :ok
    end

    defp con_env(tipo, extra \\ %{}) do
      struct!(Provider, %{
        alias: :p,
        type: tipo,
        base_url: "https://api.minimax.io/v1",
        api_key: {:system, "CANDIL_TEST_PROVIDER_KEY"},
        headers: []
      })
      |> then(&struct(&1, extra))
    end

    test "openai_compatible manda el bearer" do
      headers = Provider.auth_headers(con_env(:openai_compatible))

      assert {"authorization", "Bearer sk-del-entorno"} in headers
      assert {"content-type", "application/json"} in headers
    end

    test "openai manda el bearer y conserva la org" do
      headers = Provider.auth_headers(con_env(:openai, %{org_id: "org-1"}))

      assert {"authorization", "Bearer sk-del-entorno"} in headers
      assert {"openai-organization", "org-1"} in headers
    end

    test "anthropic manda x-api-key" do
      headers = Provider.auth_headers(con_env(:anthropic))

      assert {"x-api-key", "sk-del-entorno"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    test "una clave literal sigue funcionando" do
      # Lo de antes no se ha roto por arreglar lo de despues.
      headers =
        Provider.auth_headers(%Provider{
          alias: :p,
          type: :openai_compatible,
          base_url: "u",
          api_key: "sk-literal"
        })

      assert {"authorization", "Bearer sk-literal"} in headers
    end

    test "sin la variable puesta no se inventa una cabecera de autorizacion" do
      # `nil` es «no hay autenticacion», que es lo que un servidor local
      # quiere. Lo que no puede es mandar `Bearer ` con la clave vacia.
      System.delete_env("CANDIL_TEST_PROVIDER_KEY")

      headers = Provider.auth_headers(con_env(:openai_compatible))

      refute Enum.any?(headers, fn {nombre, _} -> nombre == "authorization" end)
      assert {"content-type", "application/json"} in headers
    end
  end

  describe "auth_headers/1" do
    test "returns correct headers for openai with org" do
      provider = %Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: "sk-test",
        org_id: "org-123"
      }

      headers = Provider.auth_headers(provider)

      assert {"authorization", "Bearer sk-test"} in headers
      assert {"content-type", "application/json"} in headers
      assert {"openai-organization", "org-123"} in headers
    end

    test "returns correct headers for openai without org" do
      provider = %Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: "sk-test",
        org_id: nil
      }

      headers = Provider.auth_headers(provider)

      assert {"authorization", "Bearer sk-test"} in headers
      assert {"content-type", "application/json"} in headers
      # Check that there's no openai-organization header
      org_headers = for {"openai-organization", _} = h <- headers, do: h
      assert org_headers == []
    end

    test "returns correct headers for openai_compatible with api_key" do
      provider = %Provider{
        alias: :groq,
        type: :openai_compatible,
        base_url: "https://api.groq.com/openai",
        api_key: "gsk_test"
      }

      headers = Provider.auth_headers(provider)

      assert {"authorization", "Bearer gsk_test"} in headers
      assert {"content-type", "application/json"} in headers
    end

    test "returns correct headers for openai_compatible without api_key" do
      provider = %Provider{
        alias: :local,
        type: :openai_compatible,
        base_url: "http://localhost:8080",
        api_key: nil
      }

      headers = Provider.auth_headers(provider)

      # Check that there's no authorization header
      auth_headers = for {"authorization", _} = h <- headers, do: h
      assert auth_headers == []
      assert {"content-type", "application/json"} in headers
    end

    test "returns correct headers for anthropic" do
      provider = %Provider{
        alias: :anthropic,
        type: :anthropic,
        base_url: "https://api.anthropic.com",
        api_key: "sk-ant-test"
      }

      headers = Provider.auth_headers(provider)

      assert {"x-api-key", "sk-ant-test"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
      assert {"content-type", "application/json"} in headers
    end

    test "returns correct headers for ollama" do
      provider = %Provider{
        alias: :ollama,
        type: :ollama,
        base_url: "http://localhost:11434"
      }

      headers = Provider.auth_headers(provider)

      assert {"content-type", "application/json"} in headers
      # Check that there's no authorization header
      auth_headers = for {"authorization", _} = h <- headers, do: h
      assert auth_headers == []
    end

    test "includes extra headers merged with type-specific headers" do
      provider = %Provider{
        alias: :test,
        type: :openai_compatible,
        base_url: "http://localhost:8080",
        headers: [{"x-custom", "value"}]
      }

      headers = Provider.auth_headers(provider)

      assert {"x-custom", "value"} in headers
      assert {"content-type", "application/json"} in headers
    end
  end

  describe "chat_url/1" do
    test "returns correct endpoint for anthropic" do
      provider = %Provider{
        alias: :anthropic,
        type: :anthropic,
        base_url: "https://api.anthropic.com"
      }

      assert Provider.chat_url(provider) == "https://api.anthropic.com/v1/messages"
    end

    test "returns correct endpoint for ollama" do
      provider = %Provider{alias: :ollama, type: :ollama, base_url: "http://localhost:11434"}
      assert Provider.chat_url(provider) == "http://localhost:11434/api/chat"
    end

    test "returns correct endpoint for openai" do
      provider = %Provider{alias: :openai, type: :openai, base_url: "https://api.openai.com"}
      assert Provider.chat_url(provider) == "https://api.openai.com/v1/chat/completions"
    end

    test "returns correct endpoint for openai_compatible" do
      provider = %Provider{
        alias: :groq,
        type: :openai_compatible,
        base_url: "https://api.groq.com/openai"
      }

      assert Provider.chat_url(provider) == "https://api.groq.com/openai/v1/chat/completions"
    end
  end

  describe "embeddings_url/1" do
    test "returns correct endpoint for ollama" do
      provider = %Provider{alias: :ollama, type: :ollama, base_url: "http://localhost:11434"}
      assert Provider.embeddings_url(provider) == "http://localhost:11434/api/embeddings"
    end

    test "returns correct endpoint for openai" do
      provider = %Provider{alias: :openai, type: :openai, base_url: "https://api.openai.com"}
      assert Provider.embeddings_url(provider) == "https://api.openai.com/v1/embeddings"
    end

    test "returns correct endpoint for openai_compatible" do
      provider = %Provider{
        alias: :groq,
        type: :openai_compatible,
        base_url: "https://api.groq.com/openai"
      }

      assert Provider.embeddings_url(provider) == "https://api.groq.com/openai/v1/embeddings"
    end
  end
end
