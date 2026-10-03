defmodule Candil.Conversation.TokenEstimatorTest do
  use ExUnit.Case, async: true

  # D8 moved the implementation to `Candil.Context.TokenEstimator`. The real
  # tests live there now; what is left here is the promise that matters to
  # consumers outside this ecosystem: the old name still answers, with the same
  # number, instead of quietly raising UndefinedFunctionError on their next
  # upgrade.
  # Calling the deprecated facade on purpose is the whole point of this file,
  # so the compiler warning it produces is left standing: it is correct, and a
  # suppression here that silently did nothing would be worse than the noise.
  # (It was tried. `@compile {:no_warn_deprecated, M}` does not take effect when
  # both modules land in the same parallel compilation batch — measured.)

  alias Candil.Context.TokenEstimator, as: New
  alias Candil.Conversation.TokenEstimator, as: Old

  @conversation %{messages: [%{role: "user", content: "hello world"}], system: "be brief"}
  @message %{role: "user", content: "hello world"}

  describe "the old name still answers" do
    test "estimate_conversation/1" do
      assert Old.estimate_conversation(@conversation) ==
               New.estimate_conversation(@conversation)
    end

    test "estimate_message/1" do
      assert Old.estimate_message(@message) == New.estimate_message(@message)
    end

    test "estimate_content/1" do
      assert Old.estimate_content("hello world") == New.estimate_content("hello world")
    end

    test "estimate_content_legacy/1" do
      assert Old.estimate_content_legacy("hello world") ==
               New.estimate_content_legacy("hello world")
    end

    test "the three aliases" do
      for {old, new} <- [
            {Old.estimate_message_tokens(@message), New.estimate_message_tokens(@message)},
            {Old.estimate_content_tokens("hi there"), New.estimate_content_tokens("hi there")},
            {Old.estimate_tokens("hi there"), New.estimate_tokens("hi there")}
          ] do
        assert old == new
      end
    end
  end
end
