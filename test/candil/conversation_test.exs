defmodule Candil.ConversationTest do
  use ExUnit.Case, async: true

  alias Candil.Conversation

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
      # Formula: 4 (overhead per message) + ceil(content_bytes / 4)
      # For "Hello" (5 bytes): 4 + ceil(5/4) = 4 + 2 = 6
      assert tokens == 6
    end

    test "handles atom keys" do
      conv = %Conversation{
        model: :llama3,
        system: nil,
        messages: [%{role: :user, content: "Hello"}]
      }

      tokens = Conversation.token_estimate(conv)
      # Same as string keys - formula accounts for content length
      assert tokens == 6
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
      # System "System prompt here" (17 bytes): 4 + div(17,4) + div(17,5) = 4 + 4 + 3 = 11
      # User "Hello" (5 bytes): 4 + div(5,4) + div(5,5) = 4 + 1 + 1 = 6
      # Assistant "Hi there!" (9 bytes): 4 + div(9,4) + div(9,5) = 4 + 2 + 1 = 7
      # Total: 11 + 6 + 7 = 24
      assert tokens == 24
    end

    test "handles missing content gracefully" do
      conv = %Conversation{
        model: :llama3,
        system: nil,
        messages: [%{role: "user"}]
      }

      tokens = Conversation.token_estimate(conv)
      # Missing content defaults to empty string: 4 (overhead) + 1 (min 1) = 5
      assert tokens == 5
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
