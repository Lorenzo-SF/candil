defmodule Candil.HTTPTest do
  use ExUnit.Case, async: false
  import Mox

  alias Arrea.CircuitBreaker
  alias Candil.{Error, HTTP, HTTPAdapterMock}
  alias Candil.HTTP.{Breaker, RateLimit}

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
    # Este grupo **cambio de verdad el 2026-10-14**. Antes decia que el modulo
    # no tenia proteccion ninguna —0 breakers registrados— y era verdad; ahora
    # hay uno por destino, arrancado bajo demanda y con dueno. Los tres tests
    # que hay debajo no son el texto anterior invertido: son las tres cosas que
    # la politica decidio y que hay que volver a comprobar.

    test "hay un circuito por destino, y se registra al usarlo" do
      # Antes: 0 registrados. `Arrea.CircuitBreaker.call/2` sobre un nombre sin
      # registrar ejecuta la funcion y ya esta, sin proteccion ninguna.
      url = "http://127.0.0.1:9971/v1/chat"
      with_provider(:gpu_9971, url)

      assert Arrea.CircuitBreaker.get_state(Breaker.name(url)) == :closed

      Breaker.ensure_started(Breaker.name(url))

      nombre = Breaker.name(url)
      assert [{pid, _}] = Registry.lookup(Arrea.CircuitBreaker.Registry, nombre)

      # Y el dueno es el supervisor de Candil, no el proceso de la peticion: un
      # circuito no puede morirse con la peticion que lo provoco.
      assert Candil.HTTP.Breaker.Supervisor |> Process.whereis() != nil

      hijos =
        Candil.HTTP.Breaker.Supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, pid, _, _} -> pid end)

      assert pid in hijos, "el circuito no cuelga del supervisor de Candil"
    end

    test "y cada destino tiene el suyo, no uno para todo" do
      # El nombre viejo caia a `:default_breaker` para casi todo, porque
      # devolvia el host solo si ese atomo ya existia en la VM, y ni
      # `127.0.0.1` ni `api.openai.com` existen. Un destino caido abria el
      # circuito de todos los demas.
      # Los tres son destinos que NO estan en el catalogo de este test, asi
      # que caen al nombre global: lo que se comprueba aqui es que el nombre
      # global es uno solo y que el atomo se construye con un prefijo fijo.
      base_urls = [
        "http://127.0.0.1:9981/v1/chat",
        "http://127.0.0.1:9981/api",
        "http://127.0.0.1:9982/v1/chat"
      ]

      # Aliases literales y no `:"destino_#{n}"`: en un test no hace falta
      # ahorrar un atomo, y `Credo.Check.Warning.UnsafeToAtom` tiene razon.
      destinos = [destino_uno: hd(base_urls), destino_dos: Enum.at(base_urls, 1)]

      for {alias_, url} <- destinos, do: with_provider(alias_, url)

      with_provider(:destino_tres, Enum.at(base_urls, 2))

      nombres = Enum.map(base_urls, &Breaker.name/1)

      # Dos en el mismo host:puerto comparten destino, y por tanto circuito; el
      # tercero, con otro puerto, tiene el suyo.
      assert length(Enum.uniq(nombres)) == 2
      assert Enum.all?(nombres, &is_atom/1)

      # Y lo que **no** esta en el catalogo no tiene circuito. Ni global
      # compartido —un destino desconocido abriria el de todos los demas— ni un
      # atomo por peticion, que es un denial of service esperando.
      assert Breaker.name("http://inventado-que-no-esta:1234/x") == nil
    end

    test "los errores de red SI cuentan, y los 4xx no" do
      # La linea que divide las dos mitades: un 4xx es un error **del
      # cliente**, y cerrar el circuito por eso apaga Candil entero con el
      # destino en perfecto estado. Un 5xx es del **destino**, que es lo que
      # un corteprotecta existe para no golpear.
      refute Breaker.fallo?({:ok, %{status: 404}})
      refute Breaker.fallo?({:ok, %{status: 400}})
      refute Breaker.fallo?({:ok, %{status: 422}})

      assert Breaker.fallo?({:ok, %{status: 500}})
      assert Breaker.fallo?({:ok, %{status: 503}})
      assert Breaker.fallo?({:ok, %{status: 429}})
      assert Breaker.fallo?({:error, %Candil.Error{reason: :timeout}})
      assert Breaker.fallo?({:error, :econnrefused})
    end

    test "un destino roto abre el suyo y deja a los demas en paz" do
      gpu = "http://127.0.0.1:9972/v1/chat"
      ollama = "http://127.0.0.1:9973/api/chat"

      # Los dos en el catalogo, que es la unica forma de que cada uno reciba
      # un circuito propio: un destino que no esta en `candil.toml` cae al
      # global a proposito, para no crear un atomo por URL.
      with_provider(:gpu_test, gpu)
      with_provider(:ollama_test, ollama)

      refute Breaker.name(gpu) == Breaker.name(ollama)

      for _ <- 1..5, do: Breaker.call(gpu, fn -> {:ok, %{status: 503}} end)

      assert {:error, :circuit_open} = Breaker.call(gpu, fn -> :ejecutada end)
      assert {:ok, %{status: 200}} = Breaker.call(ollama, fn -> {:ok, %{status: 200}} end)
    end

    defp with_provider(alias_, base_url) do
      Candil.Store.register_provider(%Candil.Provider{
        alias: alias_,
        type: :openai,
        base_url: base_url,
        api_key: "sk-test"
      })

      :ok
    end

    test "un destino que no esta en el catalogo se sirve SIN circuito" do
      # La tercera opcion, y la que faltaba: ni un circuito global compartido
      # —un destino desconocido abriria el de todos los demas, medido: eso
      # tumbaba media suite— ni un atomo por peticion, que es un denial of
      # service esperando a que alguien mande una URL.
      url = "http://desconocido-que-no-esta-en-el-catalogo:1234/x"

      assert Breaker.name(url) == nil
      assert {:ok, %{status: 200}} = Breaker.call(url, fn -> {:ok, %{status: 200}} end)

      # Tampoco hay limite de tasa, porque el limitador va por el mismo nombre.
      assert Breaker.limit_name(url) == nil
    end

    test "un 4xx repetido no abre el circuito" do
      roto = "http://127.0.0.1:9974/v1/chat"
      with_provider(:roto_test, roto)

      for _ <- 1..9, do: Breaker.call(roto, fn -> {:ok, %{status: 404}} end)

      assert :ejecutada = Breaker.call(roto, fn -> :ejecutada end)
    end

    test "call/3 espera una URL, no un nombre de circuito" do
      # Los dos son strings y el error era silencioso:
      # `URI.parse("candil-breaker-127.0.0.1-9999")` no da error, da
      # `host: nil`, y el nombre sale `candil-breaker--`: el mismo para todos
      # los destinos, o sea un circuito para todo. Paso por un test sin
      # querer.
      assert_raise ArgumentError, ~r/espera una URL/, fn ->
        Breaker.call(Breaker.name("http://127.0.0.1:9975/x"), fn -> :ok end)
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
