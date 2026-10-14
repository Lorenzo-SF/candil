defmodule Candil.HTTP do
  @moduledoc """
  Shared HTTP client with circuit breaker, retry, and rate limiting for Candil.

  Wraps `Arrea.CircuitBreaker` around all outbound HTTP calls. Uses
  `Apero.Retry` with exponential backoff for transient failures.
  Implements a sliding-window rate limiter per breaker name.

  Transport is provided by `Apero.Http` — a dedicated Finch pool managed
  by `Apero.Http.Finch`.

  ## El circuito: uno por destino, y que cuenta como fallo

  Todo esto estaba antes en este `@moduledoc`, pero **era mentira** y por eso se
  sustituyo por lo de abajo. Lo que se decia, medido el 2026-10-14: no habia
  **ningun** breaker registrado —`Arrea.CircuitBreaker.call/2` sobre un nombre
  sin registrar ejecuta la funcion y ya esta—, todos los destinos caian a
  `:default_breaker` porque el host solo se aceptaba si ese atomo ya existia en
  la VM, y un error de red contaba como **exito** porque `call/3` solo registra
  fallo cuando la funcion **lanza**.

  Las tres cosas tienen su explicacion y su arreglo en `Candil.HTTP.Breaker`,
  que es donde vive la politica:

  | Que pasa | Cuenta como fallo |
  |---|---|
  | **5xx** — el destino esta roto | si |
  | **429** — le has pedido demasiado | si |
  | **error de red, timeout, conexion rechazada** | si |
  | **otros 4xx** — tu peticion estaba mal | no |
  | excepcion | si |

  Los numeros: **5** fallos consecutivos y **30 000 ms** abierto antes de dejar
  pasar una sonda, que es el plazo de `Arrea.Command` y no uno inventado aqui.

  Y el nombre es un **string**, `"candil-breaker-<host>-<puerto>"`, no un atomo:
  el nombre viejo acababa en `:default_breaker` justo porque usaba
  `String.to_existing_atom`, que existe para no crear atomos con datos de fuera.
  Con un string el problema desaparece en vez de esquivarse, y un destino caido
  apaga su circuito y no el de al lado.

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
    * `:breaker_threshold` — fallos consecutivos antes de abrir (default: 5)
    * `:rate_limit` — max requests per second (default: no limit)

  ## Returns

    * `{:ok, Candil.HTTP.response()}` — response map with status, body, headers
    * `{:error, Candil.Error.t()}` — error with unified error types
  """
  @spec post_json(binary(), map(), [{binary(), binary()}], keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def post_json(url, body, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    rate_limit = Keyword.get(opts, :rate_limit)

    request(url, fn -> Client.do_post_json(url, body, headers, timeout) end)
    |> Retry.run(url, rate_limit, opts)
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
    rate_limit = Keyword.get(opts, :rate_limit)

    result =
      request(url, fn ->
        Client.do_post_streaming(url, body, headers, timeout, streaming_opts)
      end)
      |> Retry.run(url, rate_limit, opts)

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
  defp request(url, fun) when is_function(fun, 0) do
    fn ->
      Telemetry.emit_http(:request, %{url: url})
      started = System.monotonic_time(:microsecond)
      result = fun.()
      status = status_of(result)

      Telemetry.emit_http(
        :response,
        %{status: status, duration: System.monotonic_time(:microsecond) - started},
        %{url: url}
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
