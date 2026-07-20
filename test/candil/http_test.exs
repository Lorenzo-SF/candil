defmodule Candil.HTTPTest do
  use ExUnit.Case, async: true

  alias Candil.{Error, RateLimiter}

  describe "RateLimiter" do
    test "check/2 returns :ok when no limit set" do
      assert RateLimiter.check(:test_breaker, nil) == :ok
    end

    test "check/2 allows requests within limit" do
      # Allow 5 req/s — first request should pass
      assert RateLimiter.check(:test_within_limit, 5) == :ok
    end

    test "check/2 rate limits when exceeded" do
      breaker = :test_exceeded

      # Use 1 req/s — first passes
      assert RateLimiter.check(breaker, 1) == :ok

      # Second within same window should be rate-limited
      result = RateLimiter.check(breaker, 1)
      assert {:error, %Error{reason: :rate_limited}} = result
    end

    test "check/2 uses different windows per breaker" do
      # Different breaker names should not interfere
      RateLimiter.check(:breaker_a, 1)
      assert RateLimiter.check(:breaker_b, 1) == :ok
    end
  end
end
