defmodule Candil.StreamTest do
  use ExUnit.Case, async: true
  import Mox

  alias Apero.Http.Request
  alias Candil.{Error, HTTPAdapterMock, Model, Provider, Stream}

  setup :verify_on_exit!

  setup do
    Application.put_env(:apero, :http_adapter, HTTPAdapterMock)
    :ok
  end

  describe "chat/4 (local)" do
    test "returns error when engine not running" do
      callback = fn _chunk -> :ok end

      result = Stream.chat(:nonexistent_model, [%{role: "user", content: "Hello"}], callback, [])

      assert {:error,
              %Error{reason: :engine_not_running, context: %{engine_alias: :nonexistent_model}}} =
               result
    end
  end

  describe "el acumulador que ve Finch" do
    # `Finch.stream/5` envuelve el callback del usuario y SIEMPRE contesta
    # `{:cont, valor}`. O sea: **lo que devuelve el callback es el acumulador de
    # Finch**, y devolver una tupla lo anida una vez por chunk. Ningun test miraba
    # eso, y `do_post_streaming/5` descarta el acumulador, asi que hacia fuera
    # no se notaba. Aqui se mira el contrato, que es lo que se puede comprobar.
    test "el callback por defecto devuelve el acumulador, no una tupla" do
      cb = &Candil.HTTP.Client.default_stream_callback/2

      assert [uno] = cb.({:data, "uno"}, [])
      assert [dos, uno] = cb.({:data, "dos"}, [uno])
      assert [^uno] = cb.(:done, [uno])
    end
  end

  describe "un stream de verdad" do
    # El adapter de verdad es `Apero.Http.Adapter.Finch.stream/4`, que es
    # `Finch.stream/5`. Su callback recibe —esto es su contrato, no una opinion:
    #
    #   {:status, status}   la respuesta llego
    #   {:headers, headers}
    #   {:data, data}       un trozo del cuerpo
    #   :done               se acabo        <-- un atomo, no una tupla
    #
    # Los tests de este grupo de abajo usaban un mock que devolvia `{:ok, []}`
    # sin llamar nunca a ese callback, asi que no llegaban ni un chunk ni el
    # final. Con ese mock, `do_stream/6` se comeaba el timeout entero y
    # devolvia `:ok` igualmente: un test que pasa sin comprobar nada.
    defp finch_que_emite(trozos) when is_binary(trozos), do: finch_que_emite([trozos])

    defp finch_que_emite(trozos) do
      expect(HTTPAdapterMock, :stream, fn %Request{}, _acc, fun, _opts ->
        fun.({:status, 200}, [])
        fun.({:headers, [{"content-type", "text/event-stream"}]}, [])

        Enum.each(trozos, &fun.({:data, &1}, []))

        fun.(:done, [])
        {:ok, []}
      end)
    end

    defp recoge_chunks(parent), do: fn chunk -> send(parent, {:chunk, chunk}) end

    defp sse_de_openai, do: ~s(data: {"choices":[{"delta":{"content":"hola"}}]}\n\n)

    defp sse_de_anthropic,
      do: ~s(data: {"type":"content_block_delta","delta":{"text":"hola"}}\n\n)

    defp sse_de_ollama, do: ~s(data: {"message":{"content":"hola"},"done":false}\n\n)

    test "entrega el chunk y vuelve en cuanto llega el :done" do
      # Lo que no hacia: tardaba `receive_timeout + timeout` —600 ms aqui,
      # 150 s con los valores por defecto— porque el `:done` de Finch nunca
      # llegaba a quien espera. Y luego devolvia `:ok`, que es lo mismo que no
      # decir nada.
      finch_que_emite(sse_de_openai())
      parent = self()

      t0 = System.monotonic_time(:millisecond)

      assert :ok =
               Stream.chat(
                 model(),
                 openai_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      ms = System.monotonic_time(:millisecond) - t0

      assert_received {:chunk, %{content: "hola"}}
      assert ms < 2_000, "tardo #{ms} ms: el :done no llego y se comio el timeout"
    end

    test "cada provider entrega su propio formato" do
      for {sse, provider, etiqueta} <- [
            {sse_de_openai(), openai_provider(), "openai"},
            {sse_de_anthropic(), anthropic_provider(), "anthropic"},
            {sse_de_ollama(), ollama_provider(), "ollama"}
          ] do
        finch_que_emite(sse)
        parent = self()

        assert :ok =
                 Stream.chat(
                   model(),
                   provider,
                   [%{role: "user", content: "hi"}],
                   recoge_chunks(parent),
                   timeout_ms: 5_000,
                   receive_timeout_ms: 100
                 ),
               etiqueta

        assert_received {:chunk, %{content: "hola"}}, etiqueta
      end
    end

    test "un evento partido entre dos trozos se une" do
      # El parser tiene que aguantar que un evento SSE llegue cortado por TCP,
      # que es lo normal y no el caso raro.
      # Dos trozos TCP: el evento llega partido, que es lo normal.
      finch_que_emite([
        ~s(data: {"choices":[{"delta":{"cont),
        ~s(ent":"hola"}}]}\n\n)
      ])

      parent = self()

      assert :ok =
               Stream.chat(
                 model(),
                 openai_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      assert_received {:chunk, %{content: "hola"}}
    end

    test "un stream que se corta se dice, con su motivo y no de rebote" do
      # Lo que hacia `do_stream/6`: un `case` con `:ok` en los dos brazos, asi
      # que un timeout, un error de red y una respuesta buena eran lo mismo.
      #
      # Y la segunda mitad del fallo: el Task es el unico que sabe por que fallo,
      # y antes no avisaba a nadie. Quien esperaba se enteraba porque se le
      # acababa el tiempo —un `:timeout` que no era un timeout— con un margen
      # tan corto que ademas depended de cuando se programase el Task. Medido:
      # 2 de 4 corridas de la suite completa.
      expect(HTTPAdapterMock, :stream, fn %Request{}, _acc, _fun, _opts ->
        {:error, %Apero.Http.Error{reason: :econnrefused}}
      end)

      parent = self()

      assert {:error, %Candil.Error{reason: :econnrefused}} =
               Stream.chat(
                 model(),
                 openai_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      refute_received {:chunk, _}
    end

    test "si se corta DESPUES de entregar algo, se dice el motivo" do
      # El caso que de verdad importa: el servidor empezo a responder y se cae a
      # mitad. Sin `:done`, lo unico que sabe que algo va mal es el error del
      # Task, y por eso lo manda.
      #
      # Y lo entregado sigue entregado: el callback no se tira atras.
      expect(HTTPAdapterMock, :stream, fn %Request{}, _acc, fun, _opts ->
        fun.({:status, 200}, [])
        fun.({:data, sse_de_openai()}, [])
        # ni `:done` ni nada: la conexion se murio aqui
        {:error, %Apero.Http.Error{reason: :econnrefused}}
      end)

      parent = self()

      assert {:error, %Candil.Error{reason: :econnrefused}} =
               Stream.chat(
                 model(),
                 openai_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      assert_received {:chunk, %{content: "hola"}}
    end
  end

  describe "chat/4 (remote providers via do_stream)" do
    defp model, do: %Model{alias: "m", name: "model-x", type: :remote}

    defp openai_provider do
      %Provider{
        alias: :openai_test,
        type: :openai,
        base_url: "http://127.0.0.1:9999",
        api_key: "sk-test",
        headers: []
      }
    end

    defp ollama_provider do
      %Provider{
        alias: :ollama_test,
        type: :ollama,
        base_url: "http://127.0.0.1:11434",
        headers: []
      }
    end

    defp anthropic_provider do
      %Provider{
        alias: :anthropic_test,
        type: :anthropic,
        base_url: "http://127.0.0.1:9999",
        api_key: "sk-ant",
        headers: []
      }
    end

    test "openai provider stream returns :ok" do
      # Este mock devolvia `{:ok, []}` **sin llamar al callback**: no llegaba
      # ni un chunk ni el `:done`. Con el, el stream se comia el timeout
      # entero y devolvia `:ok` igualmente — un test que pasaba sin comprobar
      # nada. Ahora entrega un stream de verdad.
      finch_que_emite(sse_de_openai())
      parent = self()

      assert :ok =
               Stream.chat(
                 model(),
                 openai_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      assert_received {:chunk, %{content: "hola"}}
    end

    test "ollama provider stream returns :ok" do
      # Este mock devolvia `{:ok, []}` **sin llamar al callback**: no llegaba
      # ni un chunk ni el `:done`. Con el, el stream se comia el timeout
      # entero y devolvia `:ok` igualmente — un test que pasaba sin comprobar
      # nada. Ahora entrega un stream de verdad.
      finch_que_emite(sse_de_ollama())
      parent = self()

      assert :ok =
               Stream.chat(
                 model(),
                 ollama_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      assert_received {:chunk, %{content: "hola"}}
    end

    test "anthropic provider stream returns :ok" do
      # Este mock devolvia `{:ok, []}` **sin llamar al callback**: no llegaba
      # ni un chunk ni el `:done`. Con el, el stream se comia el timeout
      # entero y devolvia `:ok` igualmente — un test que pasaba sin comprobar
      # nada. Ahora entrega un stream de verdad.
      finch_que_emite(sse_de_anthropic())
      parent = self()

      assert :ok =
               Stream.chat(
                 model(),
                 anthropic_provider(),
                 [%{role: "user", content: "hi"}],
                 recoge_chunks(parent),
                 timeout_ms: 5_000,
                 receive_timeout_ms: 100
               )

      assert_received {:chunk, %{content: "hola"}}
    end
  end

  describe "extract_sse_events/1 (stateful SSE parser — CA-2)" do
    test "splits a complete event" do
      {events, rest} = Stream.extract_sse_events("data: hello\n\n")

      assert events == ["hello"]
      assert rest == ""
    end

    test "splits multiple events" do
      {events, rest} = Stream.extract_sse_events("data: a\n\ndata: b\n\ndata: c\n\n")
      assert events == ["a", "b", "c"]
      assert rest == ""
    end

    test "preserves partial event in rest" do
      {events, rest} = Stream.extract_sse_events("data: a\n\ndata: par")
      assert events == ["a"]
      assert rest == "data: par"
    end

    test "accepts CRLF line endings" do
      {events, rest} = Stream.extract_sse_events("data: a\r\n\r\ndata: b\r\n\r\n")
      assert events == ["a", "b"]
      assert rest == ""
    end

    test "tolerates mixed LF / CRLF / no line ending" do
      {events, rest} = Stream.extract_sse_events("data: a\n\ndata: b\r\n\r\ndata: c")
      assert events == ["a", "b"]
      assert rest == "data: c"
    end

    test "handles JSON payloads that span multiple lines" do
      chunk = "data: {\"a\": 1,\n\"b\": 2}\n\n"
      {events, rest} = Stream.extract_sse_events(chunk)
      assert events == ["{\"a\": 1,\n\"b\": 2}"]
      assert rest == ""
    end

    test "ignores comment lines" do
      {events, rest} = Stream.extract_sse_events(": keep-alive\n\ndata: real\n\n")
      assert events == ["real"]
      assert rest == ""
    end
  end
end
