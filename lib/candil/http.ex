defmodule Candil.HTTP do
  @moduledoc """
  Shared HTTP client with circuit breaker, retry, and rate limiting for Candil.

  Wraps `Arrea.CircuitBreaker` around all outbound HTTP calls. Uses
  `Apero.Retry` with exponential backoff for transient failures.
  Implements a sliding-window rate limiter per breaker name.

  Transport is provided by `Apero.Http` — a dedicated Finch pool managed
  by `Apero.Http.Finch`.

  ## Lo que el circuit breaker **no** hace hoy

  Nada. No es una opinion: no hay **ningun** breaker registrado, y
  `Arrea.CircuitBreaker.call/2` sobre un nombre que no esta registrado ejecuta la
  funcion y ya esta. Medido el 2026-10-14: **0** breakers registrados al
  arrancar Candil, y **10 excepciones seguidas** dejan el circuito en
  `:closed`.

  Y tampoco abririan aunque lo hubiera, por dos razones independientes:

  1. `Client.breaker_name/1` cae a `:default_breaker` para casi todo. Devuelve el
     host **solo si ese atomo ya existe en la VM**, y `127.0.0.1` no existe; lo
     mismo pasa con `api.openai.com`. Medido: las tres dan
     `:default_breaker`. Si se arreglara el registro sin arreglar el nombre,
     un destino caido abriria el circuito de todos los demas.
  2. Un error de red llega a Arrea como `{:error, _}` y cuenta como **exito**:
     `call/3` solo registra fallo cuando la funcion **lanza**. Este modulo
     convierte todo en `{:error, _}`, asi que nada lo abre.

  El reintento (`Apero.Retry`) si funciona, y el limitador tambien. Lo que no
  existe es el corte: un destino caido se sigue intentando, siempre.

  Que abra un circuito y con que politica —que errores cuentan, cuantos abren,
  cuanto dura abierto— es **decision del dueno** y no se inventa aqui. Lo que si
  se hace es que el modulo lo diga, para que nadie lo de por hecho: hay un test
  que afirma el estado real en `test/candil/http_test.exs`.
  """

  alias Candil.Error
  alias Candil.HTTP.Client
  alias Candil.HTTP.Retry
  alias Candil.Telemetry

  @default_timeout_ms 60_000
  @default_stream_timeout_ms 120_000

  @type response :: %{status: pos_integer(), body: any(), headers: list()}

  @doc """
  Performs a POST request with JSON body, protected by circuit breaker and retry.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 60_000)
    * `:retry` — enable retry with backoff (default: true)
    * `:max_retries` — maximum retry attempts (default: 3)
    * `:breaker_name` — circuit breaker name (default: from URL host)
    * `:rate_limit` — max requests per second (default: no limit)

  ## Returns

    * `{:ok, Candil.HTTP.response()}` — response map with status, body, headers
    * `{:error, Candil.Error.t()}` — error with unified error types
  """
  @spec post_json(binary(), map(), [{binary(), binary()}], keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def post_json(url, body, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    breaker = Keyword.get(opts, :breaker_name, Client.breaker_name(url))
    rate_limit = Keyword.get(opts, :rate_limit)

    request(url, breaker, fn -> Client.do_post_json(url, body, headers, timeout) end)
    |> Retry.run(breaker, rate_limit, opts)
    |> Client.wrap_error()
  end

  @doc """
  Performs a POST request with streaming response.

  The callback is called for each SSE data chunk. This function is used
  by `Candil.Stream` to handle streaming responses.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 120_000)
    * `:into` — optional accumulator for streaming

  """
  @spec post_streaming(binary(), map(), [{binary(), binary()}], keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post_streaming(url, body, headers, opts \\ [], streaming_opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_stream_timeout_ms)
    breaker = Keyword.get(opts, :breaker_name, Client.breaker_name(url))
    rate_limit = Keyword.get(opts, :rate_limit)

    result =
      request(url, breaker, fn ->
        Client.do_post_streaming(url, body, headers, timeout, streaming_opts)
      end)
      |> Retry.run(breaker, rate_limit, opts)

    case result do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, Client.wrap_reason(reason)}
    end
  end

  @doc """
  Performs a GET request.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 60_000)

  """
  @spec get(binary(), [{binary(), binary()}], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(url, headers \\ [], opts \\ []) do
    Client.get(url, headers, opts)
  end

  # One call so every outbound request is announced, and so a future third
  # transport gets it for free. Timed here rather than in the event body
  # because `Retry.run/4` may call this more than once, and a per-attempt
  # duration is more useful than a per-logical-request one.
  # Returns a function, not a result: `Retry.run/4` calls it, and may call it
  # more than once. Evaluating the request here instead would have handed
  # `Retry.run/4` the *result* of the first attempt as if it were the function,
  # which is how a circuit breaker ends up being called with a tuple.
  defp request(url, breaker, fun) when is_function(fun, 0) do
    fn ->
      Telemetry.emit_http(:request, %{url: url, breaker: breaker})
      started = System.monotonic_time(:microsecond)
      result = fun.()
      status = status_of(result)

      Telemetry.emit_http(
        :response,
        %{status: status, duration: System.monotonic_time(:microsecond) - started},
        %{url: url, breaker: breaker}
      )

      result
    end
  end

  # A transport error has no status. `nil` says "the request never got an
  # answer", which a handler can tell apart from a 500 and treat differently —
  # collapsing both to 0 would make a network partition look like a busy server.
  defp status_of({:ok, %{status: status}}), do: status
  defp status_of(_), do: nil
end
