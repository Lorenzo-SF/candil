defmodule Candil.HTTP.RateLimit do
  @moduledoc """
  The rate limit, through `Arrea.RateLimiter`.

  This replaces `Candil.RateLimiter`, a 67-line sliding window over ETS that
  did one thing: count requests per breaker inside a one-second window. It was
  written before the sibling libraries existed, and it was never tested, which
  is how a second implementation of a solved problem survives a year of CI
  without anybody noticing.

  `Arrea.RateLimiter` is a token bucket on top of `Apero.RateLimit`, so the
  limit is not merely reimplemented — it is one the rest of the ecosystem can
  observe, and the same limit can be shared with a host that is not Candil.

  ## Sliding window becomes token bucket

  Not the same algorithm, and the difference is worth naming: a sliding window
  of *N per second* lets a client send *2N* across the boundary (N just before,
  N just after). A token bucket with `capacity: N, refill_per_second: N` does
  not. For an LLM API the stricter behaviour is the correct one, and it is the
  one the user configured.

  ## When the ecosystem is not there, there is no limit

  `Arrea.RateLimiter` answers `{:error, :apero_unavailable}` if Apero is not
  loaded. Candil used to always have a working limiter, so degrading to "no
  limit" — rather than failing every request — is the behaviour that does not
  turn a missing optional dependency into an outage. It is logged, because
  silently losing a rate limit is exactly the kind of thing that should be
  noticed.

  ## Names

  Limiters are registered as `:candil_<breaker>` to stay out of Arrea's own
  namespace, which already uses names like `:llm_api`. `Candil.HTTP.Client
  .breaker_name/1` only ever returns an atom that already existed in the VM, or
  `:default_breaker`, so the set of names is bounded by the hosts in
  `candil.toml` — not by anything a remote peer can choose.
  """

  require Logger

  alias Arrea.RateLimiter

  @doc """
  Whether a request for `breaker` is within its limit, consuming one token.

  `max_per_second` of `nil` means no limit was configured, and no limiter is
  started for it.
  """
  @spec check(atom(), pos_integer() | nil) :: :ok | {:error, atom()}
  def check(_breaker, nil), do: :ok

  def check(breaker, max_per_second) when is_integer(max_per_second) and max_per_second > 0 do
    name = limiter_name(breaker)

    case ensure_started(name, max_per_second) do
      :ok ->
        case RateLimiter.check(name, 1) do
          {:error, :apero_unavailable} = reason ->
            degraded(breaker, reason)

          other ->
            other
        end

      {:error, _reason} = error ->
        degraded(breaker, error)
    end
  end

  def check(_breaker, _max_per_second), do: :ok

  # `limiter_name/1` is the one place in Candil that builds an atom from a
  # value which came out of a file, and it is the only reason this file opts
  # out of `Credo.Check.Warning.UnsafeToAtom`.
  #
  # The names are `:candil_` plus a host that `Candil.HTTP.Client
  # .breaker_name/1` has *already* turned into an existing atom, so the set is
  # bounded by the providers in `candil.toml` — not by anything a remote peer
  # can send, which is what the check protects against. And
  # `Arrea.RateLimiter` registers by atom name, so there is no tuple to pass
  # instead.
  #
  # `disable-for-this-file` rather than `disable-next-line` because the check
  # reports the interpolated atom's own line and the line-scoped form did not
  # take; two working suppressions for one is not better than one.
  # credo:disable-for-this-file Credo.Check.Warning.UnsafeToAtom

  @doc """
  The registered name for a breaker's limiter.
  """
  @spec limiter_name(atom()) :: atom()
  def limiter_name(breaker) when is_atom(breaker) do
    :"candil_#{breaker}"
  end

  # A limiter is started once per breaker, and the *first* configuration wins:
  # if a breaker is already running with capacity 5 and a later call asks for
  # 10, the running limiter keeps 5 and this returns `:ok` rather than an
  # error. That is deliberate, and it is also the one sharp edge here — a
  # caller that changes the rate at runtime gets the old one, silently.
  #
  # It is safe because the rate comes from the provider's config and does not
  # change between calls in a process's life. If two processes race to start
  # it, one gets `{:error, {:already_started, pid}}` and both keep the limiter
  # that won, which is the same "first one wins" rule one level up.
  defp ensure_started(name, max_per_second) do
    case RateLimiter.start_link(name,
           capacity: max_per_second,
           refill_per_second: max_per_second * 1.0
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp degraded(breaker, reason) do
    Logger.debug(
      "[Candil.HTTP.RateLimit] no limit for #{breaker}: #{inspect(reason)}. " <>
        "The request goes through; a missing optional dependency must not take " <>
        "the API down with it."
    )

    :ok
  end
end
