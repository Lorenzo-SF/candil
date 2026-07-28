defmodule Candil.HTTPTest do
  use ExUnit.Case, async: false

  alias Candil.{Error, HTTP, RateLimiter}

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

  describe "get/3 with invalid URL" do
    test "returns error (any wrapper) for unreachable host" do
      # Using a non-routable IP to force connection failure
      result = HTTP.get("http://192.0.2.1:1/", [], timeout_ms: 500, retry: false)
      # Accept any error form (some wrappers nest in {:ok, {:error, _}})
      assert match?({:error, _}, result) or match?({:ok, {:error, _}}, result)
    end
  end

  describe "post_json/4 with invalid URL" do
    test "returns error for unreachable host" do
      result = HTTP.post_json("http://192.0.2.1:1/", %{}, [], timeout_ms: 500, retry: false)
      assert match?({:error, _}, result) or match?({:ok, {:error, _}}, result)
    end
  end

  describe "post_streaming/5 with invalid URL" do
    test "returns error for unreachable host" do
      result =
        HTTP.post_streaming("http://192.0.2.1:1/", %{}, [], timeout_ms: 500, retry: false)

      assert match?({:error, _}, result) or match?({:ok, {:error, _}}, result)
    end
  end
end
