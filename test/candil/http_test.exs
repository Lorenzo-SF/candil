defmodule Candil.HTTPTest do
  use ExUnit.Case, async: false
  import Mox

  alias Arrea.CircuitBreaker
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

  describe "el circuit breaker: lo que hay y lo que no" do
    test "NO hay ningun breaker registrado: hoy no hay proteccion" do
      # Este test existe para que nadie crea lo que no hay. El `@moduledoc` de
      # `Candil.HTTP` lo dice, pero un modulo que lo dice se lee una vez y un
      # test que lo afirma se lee cada vez que alguien rompe algo.
      #
      # Medido el 2026-10-14: 0 breakers registrados, 10 excepciones seguidas y
      # el circuito sigue en `:closed`.
      registrados =
        Arrea.CircuitBreaker.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])

      assert registrados == [], """
      Candil tiene breakers registrados: #{inspect(registrados)}.

      Eso cambia el contrato del modulo, asi que hay que decidir la politica
      (que errores abren el circuito, cuantos, cuanto dura) y reescribir el
      `@moduledoc` de `Candil.HTTP`, que hoy dice que no hay proteccion.
      """
    end

    test "y aunque lo hubiera, casi todo caeria al mismo nombre" do
      # El nombre sale del host **solo si ese atomo ya existe**. `127.0.0.1` no
      # existe, y `api.openai.com` tampoco: los tres dan `:default_breaker`.
      # El `existing_atom` es a proposito —sin el, un peer remoto podria crear
      # atomos con cada URL que mandase—, pero su efecto secundario es que no
      # hay un circuito por destino.
      for url <- [
            "http://127.0.0.1:9999/v1/chat/completions",
            "http://127.0.0.1:11434/api/chat",
            "https://api.openai.com/v1/chat/completions"
          ] do
        assert Candil.HTTP.Client.breaker_name(url) == :default_breaker, url
      end
    end

    test "un error de red no cuenta como fallo: para Arrea es un exito" do
      # El tercero de los motivos por los que el circuito no protege, y el unico
      # de los tres que se puede **demostrar con un circuito de verdad**: se
      # registra uno, se le pega, y se ve que no se abre.
      #
      # `call/3` solo cuenta fallo cuando la funcion **lanza**. Una peticion
      # fallida llega a esta capa como `{:error, _}`, que para Arrea es un
      # exito —y a este modulo le sale un error, no una excepcion.
      nombre = :breaker_del_test

      # Arrea 3.1 no tiene `ensure_started/1`: el supervisor solo arranca el
      # Registry, y cada breaker se levanta a mano con `start_link/1`. Que no
      # haya ningun `ensure_started` en Candil es parte del hallazgo.
      {:ok, _} = CircuitBreaker.start_link(name: nombre, threshold: 3, timeout: 60_000)

      for _ <- 1..5 do
        assert {:ok, {:error, _}} =
                 CircuitBreaker.call(nombre, fn -> {:error, :econnrefused} end)
      end

      # Cinco errores de red y el circuito sigue cerrado: no protege.
      assert CircuitBreaker.get_state(nombre) == :closed

      # Y no es que el circuito no funcione: cinco excepciones lo abren.
      for _ <- 1..5 do
        try do
          CircuitBreaker.call(nombre, fn -> raise "boom" end)
        rescue
          _ -> :ok
        end
      end

      assert CircuitBreaker.get_state(nombre) == :open
    end
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
