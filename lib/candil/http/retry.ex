defmodule Candil.HTTP.Retry do
  @moduledoc false

  alias Apero.Retry, as: AperoRetry
  alias Candil.HTTP.Breaker
  alias Candil.HTTP.RateLimit

  @doc """
  Envuelve una peticion con limitador, **circuito por destino** y reintentos.

  El circuito es `Candil.HTTP.Breaker`, y el orden importa: primero el
  limitador, luego el circuito, y por dentro los reintentos. Ese orden es el que
  hace que la politica de reintentos siga significando algo —reintentar un
  destino que acaba de abrir el circuito no es reintentar, es golpear mas fuerte
  una puerta cerrada—.

  Aqui se pasa la **URL**, no un nombre de circuito: `Breaker.call/3` saca el
  nombre de ahi y por lo tanto no puede recibir un nombre ya sacado.
  """
  def run(raw_request_fn, url, rate_limit, opts) do
    request_fn = fn ->
      with :ok <- check_rate_limit(url, rate_limit) do
        Breaker.call(url, raw_request_fn, breaker_opts(opts))
      end
    end

    if Keyword.get(opts, :retry, true) do
      request_fn
      |> AperoRetry.with(
        max_attempts: Keyword.get(opts, :max_retries, 3) + 1,
        base_delay: Keyword.get(opts, :base_delay, 1000),
        max_delay: Keyword.get(opts, :max_delay, 30_000),
        retry_on: fn
          {:ok, %{status: status}} when status in 429..599 -> true
          {:error, %{reason: :timeout}} -> true
          _ -> false
        end
      )
    else
      request_fn.()
    end
  end

  @doc """
  Que circuit breaker, con su defecto explicito.

  `:breaker_name` en las opciones **se sigue aceptando** y solo se usa para
  poner el umbral a mano, que es lo que hacen los tests. Antes era el nombre
  entero del circuito, y por eso el defecto era `:default_breaker` para todo.
  """
  @spec breaker_opts(keyword()) :: keyword()
  def breaker_opts(opts) do
    case Keyword.get(opts, :breaker_name) do
      nil -> []
      _ignorado -> []
    end
    |> maybe_threshold(Keyword.get(opts, :breaker_threshold))
  end

  defp maybe_threshold(opts, nil), do: opts
  defp maybe_threshold(opts, umbral), do: Keyword.put(opts, :threshold, umbral)

  defp check_rate_limit(url, max_per_second) do
    case Breaker.limit_name(url) do
      nil -> :ok
      nombre -> RateLimit.check(nombre, max_per_second)
    end
  end
end
