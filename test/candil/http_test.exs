defmodule Candil.HTTPTest do
  use ExUnit.Case, async: false
  import Mox

  alias Candil.{Error, HTTP, HTTPAdapterMock}
  alias Candil.HTTP.RateLimit

  setup :verify_on_exit!

  setup do
    # Simulate an unreachable host: every request/stream fails with a
    # connection error, matching what the "invalid URL" tests expect.
    stub(HTTPAdapterMock, :request, fn %Apero.Http.Request{} ->
      {:error, %Apero.Http.Error{reason: :econnrefused}}
    end)

    stub(HTTPAdapterMock, :stream, fn %Apero.Http.Request{}, _acc, _fun, _opts ->
      {:error, %Apero.Http.Error{reason: :econnrefused}}
    end)

    :ok
  end

  describe "the rate limit" do
    test "no limit configured means no limiter is started and every request passes" do
      assert RateLimit.check(:test_breaker, nil) == :ok
    end

    test "allows requests within the limit" do
      assert RateLimit.check(:test_within_limit, 5) == :ok
    end

    test "rate limits when the bucket is empty" do
      breaker = :test_exceeded

      assert RateLimit.check(breaker, 1) == :ok
      assert RateLimit.check(breaker, 1) == {:error, :rate_limited}
    end

    test "one breaker's bucket does not drain another's" do
      # The old sliding window kept a per-breaker list keyed by the breaker, and
      # so does the token bucket — but keyed by a *namespaced* name, so a
      # limiter here cannot collide with one Arrea or another host started.
      a = :breaker_a
      b = :breaker_b

      assert RateLimit.check(a, 1) == :ok
      assert RateLimit.check(b, 1) == :ok
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
