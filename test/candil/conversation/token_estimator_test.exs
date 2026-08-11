defmodule Candil.Conversation.TokenEstimatorTest do
  use ExUnit.Case, async: true

  alias Candil.Conversation.TokenEstimator

  describe "estimate_content/1 (per-word heuristic)" do
    test "counts words" do
      assert TokenEstimator.estimate_content("hello world") == 2
      assert TokenEstimator.estimate_content("") == 0
    end

    test "adds extra tokens for long words" do
      # 7 chars → 1 + div(7, 6) = 2
      assert TokenEstimator.estimate_content("antidis") == 2
      # 24 chars → 1 + 4 = 5
      assert TokenEstimator.estimate_content("antidisestablishmentarianism") == 5
    end

    test "handles non-binary input as zero" do
      assert TokenEstimator.estimate_content(nil) == 0
      assert TokenEstimator.estimate_content(123) == 0
    end
  end

  describe "estimate_content_legacy/1 (4 chars per token)" do
    test "uses ceil(byte_size/4)" do
      assert TokenEstimator.estimate_content_legacy("abcd") == 1
      assert TokenEstimator.estimate_content_legacy("abcde") == 2
      assert TokenEstimator.estimate_content_legacy("") == 0
    end

    test "handles non-binary input as zero" do
      assert TokenEstimator.estimate_content_legacy(nil) == 0
    end
  end

  describe "estimate_message/1" do
    test "counts string content" do
      assert TokenEstimator.estimate_message(%{role: "user", content: "hello world"}) == 2
    end

    test "counts multimodal parts (text + images)" do
      msg = %{
        role: "user",
        content: [
          %{type: :text, text: "look"},
          %{type: :image}
        ]
      }

      # 1 word (1 token) + 100 for the image
      assert TokenEstimator.estimate_message(msg) == 101
    end

    test "returns 0 for unknown shapes" do
      assert TokenEstimator.estimate_message(%{}) == 0
      assert TokenEstimator.estimate_message(nil) == 0
    end
  end

  describe "estimate_conversation/1" do
    test "sums messages plus system prompt" do
      conv = %{
        messages: [%{role: "user", content: "hi there"}, %{role: "assistant", content: "yo"}],
        system: "you are a bot"
      }

      # 2 + 1 + 4 = 7
      assert TokenEstimator.estimate_conversation(conv) == 7
    end

    test "works without system prompt" do
      conv = %{messages: [%{role: "user", content: "hello"}], system: nil}
      assert TokenEstimator.estimate_conversation(conv) == 1
    end
  end

  describe "backwards-compatible aliases" do
    test "estimate_message_tokens/1 delegates to estimate_message/1" do
      assert TokenEstimator.estimate_message_tokens(%{role: "user", content: "a b"}) == 2
    end

    test "estimate_content_tokens/1 delegates to estimate_content/1" do
      assert TokenEstimator.estimate_content_tokens("a b") == 2
      assert TokenEstimator.estimate_content_tokens(nil) == 0
    end

    test "estimate_tokens/1 delegates to estimate_content/1" do
      assert TokenEstimator.estimate_tokens("a b") == 2
      assert TokenEstimator.estimate_tokens(nil) == 0
    end
  end
end