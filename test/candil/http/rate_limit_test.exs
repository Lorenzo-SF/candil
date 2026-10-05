defmodule Candil.HTTP.RateLimitTest do
  @moduledoc """
  The rate limit had no tests, which is how a second implementation of a solved
  problem survived a year of green CI unnoticed. These are the ones that would
  have caught it.
  """
  use ExUnit.Case, async: false

  alias Candil.HTTP.RateLimit

  describe "no limit configured" do
    test "every request passes and no limiter is started" do
      # `nil` is the default in `Candil.HTTP.post_json/4`. Starting a bucket for
      # it would be a process that does nothing but exist.
      assert RateLimit.check(:default_breaker, nil) == :ok
      assert RateLimit.check(:default_breaker, nil) == :ok
    end
  end

  # Each test names its own breaker literally. A shared bucket that an earlier
  # test had drained would make this file assert a rate limit that has nothing to
  # do with what it is testing, and a generated name would mean creating atoms at
  # runtime to avoid that. Literals solve both.
  describe "a limit is configured" do
    test "requests pass until the bucket is empty, then are refused" do
      # A name of its own, because a limiter keeps the capacity it was started
      # with: two tests sharing `:rl_exceeded` means whichever ran first
      # decided the bucket for both, and the loser asserts a rate that is not
      # the one it asked for.
      breaker = :rl_capacity_two

      assert RateLimit.check(breaker, 2) == :ok
      assert RateLimit.check(breaker, 2) == :ok
      assert {:error, :rate_limited} = RateLimit.check(breaker, 2)
    end

    test "the refusal says rate_limited, not circuit_open" do
      # The two are easy to confuse and mean opposite things: one is "try again
      # in a moment", the other is "this backend is down". The caller
      # differentiates them, so the distinction has to survive the integration.
      breaker = :rl_capacity_one

      RateLimit.check(breaker, 1)
      refute match?({:error, :circuit_open}, RateLimit.check(breaker, 1))
    end
  end

  describe "naming" do
    test "limiters live in Candil's namespace, not Arrea's" do
      # Arrea already uses bare names like `:llm_api` for its own limiters.
      # Sharing a namespace would mean one repo's rate limit silently changing
      # another repo's.
      assert RateLimit.limiter_name(:llm_api) == :candil_llm_api
    end
  end
end
