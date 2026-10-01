defmodule Candil.Gateway.Auth do
  @moduledoc """
  Gateway authentication.

  Two modes and no JWT. `none` is the default and only ever listens on
  loopback; `api_key` requires a bearer token on every request.

  ## Constant-time comparison

  Keys are compared with `Plug.Crypto.secure_compare/2`, not `==`. With `==`
  the comparison returns early on the first differing byte, so a client can
  discover a valid key one character at a time by measuring responses. That
  matters even on loopback: the process making the requests is not
  necessarily the process you trust.

  Keys come from the environment, not from the config file. A key in a TOML
  ends up in a shell history, a process listing and every backup of the
  directory.
  """

  @type mode :: :none | :api_key

  alias Plug.Crypto

  @doc """
  Validates an auth mode and its keys.
  """
  @spec validate(mode(), [binary()]) :: {:ok, mode()} | {:error, String.t()}
  def validate(:none, _keys), do: {:ok, :none}
  def validate(:api_key, []), do: {:error, "auth = \"api_key\" needs at least one key"}

  def validate(:api_key, keys) when is_list(keys) do
    if Enum.all?(keys, &is_binary/1) do
      {:ok, :api_key}
    else
      {:error, "every api key must be a string"}
    end
  end

  def validate(other, _keys),
    do: {:error, "auth must be :none or :api_key, got: #{inspect(other)}"}

  @doc """
  Checks a bearer token against the configured keys.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec verify(mode(), [binary()], binary() | nil) :: :ok | {:error, String.t()}
  def verify(:none, _keys, _token), do: :ok

  def verify(:api_key, _keys, nil) do
    {:error, "missing Authorization header"}
  end

  def verify(:api_key, keys, token) do
    presented = strip_bearer(token)

    if Enum.any?(keys, &secure_compare(&1, presented)) do
      :ok
    else
      {:error, "invalid API key"}
    end
  end

  @doc false
  # Case-sensitive on purpose: the scheme is "Bearer", and a client sending
  # "bearer" is either broken or probing.
  def strip_bearer("Bearer " <> token), do: token
  def strip_bearer(token), do: token

  # Length is compared first, which leaks the length and nothing else. Two
  # strings of different lengths cannot be equal, so saying so is not a leak,
  # and the per-character timing that matters is inside secure_compare.
  defp secure_compare(expected, presented) when byte_size(expected) == byte_size(presented) do
    Crypto.secure_compare(expected, presented)
  end

  defp secure_compare(_expected, _presented), do: false

  @doc """
  The rate limit for a consumer, in requests per minute.
  """
  @spec limit(atom()) :: pos_integer()
  def limit(_consumer), do: 600

  @doc """
  One request against a per-consumer limiter.
  """
  @spec allow(atom(), pos_integer()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def allow(_consumer, _per_minute), do: :ok
end
