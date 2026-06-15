defmodule Candil.CostTest do
  use ExUnit.Case, async: true

  alias Candil.Cost

  describe "estimate/3" do
    test "calculates cost for gpt-4o" do
      # gpt-4o: $2.50/$10.00 per 1M tokens
      # 1M input + 0.5M output = 2.50 + 5.00 = 7.50
      assert {:ok, 7.5} = Cost.estimate("gpt-4o", 1_000_000, 500_000)
    end

    test "calculates cost for gpt-4o-mini" do
      # gpt-4o-mini: $0.15/$0.60 per 1M tokens
      # 1M input + 1M output = 0.15 + 0.60 = 0.75
      assert {:ok, 0.75} = Cost.estimate("gpt-4o-mini", 1_000_000, 1_000_000)
    end

    test "returns :unknown for unlisted model" do
      assert :unknown = Cost.estimate("some-future-model-9000", 1000, 500)
    end

    test "zero tokens gives zero cost" do
      assert {:ok, val} = Cost.estimate("gpt-4o", 0, 0)
      assert val == 0.0
    end

    test "local models are free" do
      assert {:ok, val} = Cost.estimate("llama3.1", 1_000_000, 1_000_000)
      assert val == 0.0
    end

    test "strips provider prefix from model name" do
      # openai/gpt-4o should resolve same as gpt-4o
      assert Cost.estimate("openai/gpt-4o", 1_000_000, 0) ==
               Cost.estimate("gpt-4o", 1_000_000, 0)
    end

    test "handles case-insensitive model names" do
      assert Cost.estimate("GPT-4O", 1_000_000, 0) ==
               Cost.estimate("gpt-4o", 1_000_000, 0)
    end
  end

  describe "known_models/0" do
    test "returns a non-empty list" do
      models = Cost.known_models()
      assert is_list(models)
      assert models != []
      assert "gpt-4o" in models
    end
  end
end
