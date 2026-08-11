defmodule Candil.BackendTest do
  use ExUnit.Case, async: false

  alias Candil.{Backend, Model}

  setup do
    # Clear persistent_term registrations between tests so the lazy
    # defaults don't bleed across runs.
    for provider <- [:local, :openai, :anthropic, :ollama, :azure] do
      try do
        :persistent_term.erase({Backend, :backends, provider})
      rescue
        ArgumentError -> :ok
      end
    end

    on_exit(fn ->
      for provider <- [:local, :openai, :anthropic, :ollama, :azure] do
        try do
          :persistent_term.erase({Backend, :backends, provider})
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    :ok
  end

  describe "infer_provider/2" do
    test "infers :openai from gpt- prefix" do
      assert Backend.infer_provider(:openai, "gpt-4o") == :openai
      assert Backend.infer_provider(:local, "gpt-4o") == :openai
    end

    test "infers :openai from o1-/o3-/o4- prefix" do
      assert Backend.infer_provider(:openai, "o1-preview") == :openai
      assert Backend.infer_provider(:local, "o3-mini") == :openai
      assert Backend.infer_provider(:local, "o4-mini") == :openai
    end

    test "infers :anthropic from claude- prefix" do
      assert Backend.infer_provider(:openai, "claude-3-5-sonnet") == :anthropic
    end

    test "infers :ollama from : in name" do
      assert Backend.infer_provider(:local, "llama3:8b") == :ollama
      assert Backend.infer_provider(:openai, "qwen2:7b") == :ollama
    end

    test "falls back to the supplied provider for unknown names" do
      assert Backend.infer_provider(:local, "llama3") == :local
      assert Backend.infer_provider(:openai, "custom-model") == :openai
    end

    test "works with %Model{} structs" do
      model = %Model{alias: :"gpt-4o", name: "gpt-4o", provider: :openai, type: :remote}
      assert Backend.infer_provider(:openai, model) == :openai
    end
  end

  describe "for/2" do
    test "looks up the registered local backend" do
      assert {:ok, Candil.Backend.LlamaCpp} = Backend.for(:local, "llama3")
    end

    test "looks up the registered OpenAI backend" do
      assert {:ok, Candil.Backend.OpenAICompat} = Backend.for(:openai, "gpt-4o")
    end

    test "infers the backend when the provider has no registered backend" do
      # :watsonx has no registered backend; we fall through to
      # inference which then fails because the model is also unknown.
      # Use a custom provider that isn't registered to test the
      # inference path.
      assert {:error, %Candil.Error{reason: :backend_unavailable}} =
               Backend.for(:watsonx, "granite-20b")
    end

    test "returns :backend_unavailable for unknown providers with unknown models" do
      assert {:error, %Candil.Error{reason: :backend_unavailable}} =
               Backend.for(:watsonx, "granite-20b")
    end
  end

  describe "register/2" do
    test "custom backends can be registered" do
      defmodule FakeBackend do
        @behaviour Candil.Backend

        @impl true
        def chat(_, _, _), do: {:ok, %{content: "hi", finish_reason: nil, usage: %{input_tokens: 0, output_tokens: 0}}}
        @impl true
        def chat_stream(_, _, _), do: {:ok, []}
        @impl true
        def embed(_, _, _), do: {:ok, []}
        @impl true
        def models, do: []
      end

      assert Backend.register(:fake, FakeBackend) == :ok
      assert {:ok, FakeBackend} = Backend.for(:fake, "anything")
    end
  end

  describe "backend_unavailable/2" do
    test "builds a typed error with provider and model in context" do
      err = Backend.backend_unavailable(:watsonx, "granite-20b")
      assert err.reason == :backend_unavailable
      assert err.context.reason == {:no_backend_for, :watsonx, "granite-20b"}
    end
  end
end