defmodule Candil.ConversationTest do
  use ExUnit.Case, async: true

  alias Candil.Conversation

  describe "D8 · what was decided about this module" do
    test "the docstring names the replacement and when it goes" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Conversation)

      assert doc =~ "chat_with_context/4"
      assert doc =~ "4.1.0"
    end

    test "el reemplazo existe, y es el que el modulo nombra" do
      # Este test afirmaba que `chat_with_context/4` NO existia, y hacia falta:
      # era el marcador de "bloqueado" (§3.6). Con el parche integrado, el
      # nombre del doc y la realidad coinciden, y eso es lo que se comprueba.
      assert Code.ensure_loaded?(Candil)
      assert function_exported?(Candil, :chat_with_context, 4)
    end

    test "Conversation.Context is gone, and the estimator moved rather than was copied" do
      # D8: `Conversation.Context` had never left the house, so it is removed
      # and not deprecated. Two copies of the estimator would be worse than
      # either moving or deleting, so it moved.
      refute Code.ensure_loaded?(Candil.Conversation.Context)

      assert Code.ensure_loaded?(Candil.Context.TokenEstimator)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil.Context.TokenEstimator} = Code.ensure_loaded(Candil.Context.TokenEstimator)
      assert function_exported?(Candil.Context.TokenEstimator, :estimate_content, 1)
    end

    test "the old estimator name still works, delegating to the new home" do
      # Consumers outside the ecosystem call this by its old name. Broken, they
      # would not get a deprecation warning first; they would just stop.
      assert Candil.Conversation.TokenEstimator.estimate_content("hello world") ==
               Candil.Context.TokenEstimator.estimate_content("hello world")
    end
  end

  describe "new/1" do
    test "creates a conversation with model" do
      conv = Conversation.new(model: :llama3)
      assert conv.model == :llama3
      assert conv.provider == nil
      assert conv.system == nil
      assert conv.messages == []
      assert conv.max_context_tokens == 4096
    end

    test "creates a conversation with system prompt" do
      conv = Conversation.new(model: :llama3, system: "You are helpful.")
      assert conv.system == "You are helpful."
    end

    test "creates a conversation with custom max_context_tokens" do
      conv = Conversation.new(model: :llama3, max_context_tokens: 8192)
      assert conv.max_context_tokens == 8192
    end

    test "creates a conversation with provider" do
      provider = %{__struct__: Candil.Provider, alias: :openai}
      conv = Conversation.new(model: :gpt4o, provider: provider)
      assert conv.provider == provider
    end

    test "stores extra opts" do
      conv = Conversation.new(model: :llama3, temperature: 0.8, max_tokens: 1000)
      assert conv.opts == [temperature: 0.8, max_tokens: 1000]
    end

    test "requires model option" do
      assert_raise KeyError, fn ->
        Conversation.new([])
      end
    end

    test "drops known options from opts" do
      conv =
        Conversation.new(
          model: :llama3,
          system: "You are helpful.",
          max_context_tokens: 8192,
          temperature: 0.8
        )

      assert conv.opts == [temperature: 0.8]
    end
  end

  describe "reset/1" do
    test "clears messages but keeps config" do
      conv = %Conversation{
        model: :llama3,
        system: "You are helpful.",
        messages: [
          %{role: "user", content: "Hello"},
          %{role: "assistant", content: "Hi!"}
        ],
        max_context_tokens: 4096
      }

      reset = Conversation.reset(conv)

      assert reset.messages == []
      assert reset.model == :llama3
      assert reset.system == "You are helpful."
      assert reset.max_context_tokens == 4096
    end
  end

  describe "messages/1" do
    test "returns empty list when no system and no messages" do
      conv = Conversation.new(model: :llama3)
      assert Conversation.messages(conv) == []
    end

    test "returns messages without system prompt" do
      conv = %Conversation{
        model: :llama3,
        system: nil,
        messages: [%{role: "user", content: "Hello"}]
      }

      assert Conversation.messages(conv) == [%{role: "user", content: "Hello"}]
    end

    test "prepends system message when system is set" do
      conv = %Conversation{
        model: :llama3,
        system: "You are helpful.",
        messages: [%{role: "user", content: "Hello"}]
      }

      messages = Conversation.messages(conv)
      assert length(messages) == 2
      assert hd(messages) == %{role: "system", content: "You are helpful."}
      assert List.last(messages) == %{role: "user", content: "Hello"}
    end
  end

  describe "token_estimate/1" do
    test "returns 0 for empty conversation" do
      conv = Conversation.new(model: :llama3)
      assert Conversation.token_estimate(conv) == 0
    end

    test "estimates tokens based on content length with overhead" do
      conv = %Conversation{
        model: :llama3,
        system: nil,
        messages: [%{role: "user", content: "Hello"}]
      }

      tokens = Conversation.token_estimate(conv)
      # Formula (CA-12): 4 (overhead per message) + estimate_content("Hello")
      # estimate_content counts 1 token per word + 1 extra per 6 chars.
      # "Hello" (1 word, 5 chars) = 1 + 0 = 1. Total = 4 + 1 = 5.
      assert tokens == 5
    end

    test "handles atom keys" do
      conv = %Conversation{
        model: :llama3,
        system: nil,
        messages: [%{role: :user, content: "Hello"}]
      }

      tokens = Conversation.token_estimate(conv)
      # Atom-keyed role is normalised to string before counting.
      assert tokens == 5
    end

    test "sums tokens for multiple messages with overhead" do
      conv = %Conversation{
        model: :llama3,
        system: "System prompt here",
        messages: [
          %{role: "user", content: "Hello"},
          %{role: "assistant", content: "Hi there!"}
        ]
      }

      tokens = Conversation.token_estimate(conv)
      # Formula (CA-12): per-word heuristic + 4 overhead per message.
      # System "System prompt here":
      #   System (6 chars) = 1 + 1 = 2, prompt (6) = 2, here (4) = 1 → 5.
      # User "Hello": 1 word → 1. + 4 = 5.
      # Assistant "Hi there!": Hi (2) = 1, there! (6) = 2 → 3. + 4 = 7.
      # Total: 5 + 5 + 7 = 17.
      assert tokens == 17
    end

    test "handles missing content gracefully" do
      conv = %Conversation{
        model: :llama3,
        system: nil,
        messages: [%{role: "user"}]
      }

      tokens = Conversation.token_estimate(conv)
      # Missing content defaults to empty string: ceil(0/4) + 4 = 0 + 4 = 4
      assert tokens == 4
    end
  end

  describe "turn_count/1" do
    test "returns 0 for empty conversation" do
      conv = Conversation.new(model: :llama3)
      assert Conversation.turn_count(conv) == 0
    end

    test "counts user messages" do
      conv = %Conversation{
        model: :llama3,
        messages: [
          %{role: "user", content: "Hello"},
          %{role: "assistant", content: "Hi!"},
          %{role: "user", content: "How are you?"}
        ]
      }

      assert Conversation.turn_count(conv) == 2
    end

    test "handles atom role keys" do
      conv = %Conversation{
        model: :llama3,
        messages: [
          %{role: "user", content: "Hello"}
        ]
      }

      assert Conversation.turn_count(conv) == 1
    end
  end
end
