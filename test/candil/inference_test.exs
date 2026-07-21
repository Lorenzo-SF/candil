defmodule Candil.InferenceTest do
  use ExUnit.Case, async: true

  alias Candil.{Config, Error, Inference, Model}

  describe "chat_local/3" do
    test "returns error when model not found" do
      result = Inference.chat_local(:nonexistent_model, [%{role: "user", content: "Hello"}], [])

      assert {:error,
              %Error{reason: :model_not_found, context: %{model_alias: :nonexistent_model}}} =
               result
    end

    test "returns error when model is remote" do
      # Register a remote model
      model = %Model{
        alias: :remote_test,
        type: :remote,
        name: "gpt-4o",
        provider: :openai,
        usage: [:chat]
      }

      Config.register_model(model)

      result = Inference.chat_local(:remote_test, [%{role: "user", content: "Hello"}], [])

      assert {:error, %Error{reason: :invalid_request}} = result
      assert elem(result, 1).context.message =~ "remote"
    after
      Config.deregister_model(:remote_test)
    end
  end

  describe "embed_local/3" do
    test "returns error when model not found" do
      result = Inference.embed_local(:nonexistent_model, ["Hello"], [])

      assert {:error,
              %Error{reason: :model_not_found, context: %{model_alias: :nonexistent_model}}} =
               result
    end

    test "returns error when model is remote" do
      model = %Model{
        alias: :remote_embed_test,
        type: :remote,
        name: "text-embedding-3-small",
        provider: :openai,
        usage: [:embeddings]
      }

      Config.register_model(model)

      result = Inference.embed_local(:remote_embed_test, ["Hello"], [])

      assert {:error, %Error{reason: :invalid_request}} = result
      assert elem(result, 1).context.message =~ "remote"
    after
      Config.deregister_model(:remote_embed_test)
    end
  end
end
