defmodule Candil.CLI.ServeTest do
  @moduledoc """
  `candil serve` — la mitad de la fase 8 que faltaba.

  ## Que prueba este fichero, y por que

  El gateway ya tenia sus tests —y los de punta a punta, con HTTP de verdad—;
  lo que no existia era la forma de levantarlo **desde el terminal**. Aqui se
  prueba el comando: que un flag mal escrito no arranca nada, que el banner dice
  el puerto de verdad, que las claves llegan al socket (401 sin ellas, 200 con
  ellas) y —el mas importante— que `run/1` **se queda**, que es lo unico que un
  cliente OpenAI necesita de un servidor.

  `run/1` bloquea, asi que el ultimo test lo arranca en otro proceso y comprueba
  el contrato desde fuera: sigue vivo, el banner lleva el puerto de verdad, y
  cuando el proceso muere, el puerto se cierra. Es la unica forma de probar el
  «se queda» sin quedarse.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Candil.CLI
  alias Candil.CLI.Serve

  @api_keys_env "CANDIL_API_KEYS"

  setup_all do
    # `Finch` no lo arranca la app en `test`: lo levanta quien lo usa. Se
    # arranca **desenlazado** a proposito — `Finch.start_link/1` queda ligado al
    # proceso que lo arranca, y este `setup_all` muere cuando el modulo
    # termina; un Finch ligado aqui dejaria a otro fichero con «unknown
    # registry» si le toca despues. Desenlazado vive lo que viva la suite.
    case Process.whereis(Finch) do
      nil ->
        {:ok, pid} = Finch.start_link(name: Finch)
        Process.unlink(pid)

      _pid ->
        :ok
    end

    :ok
  end

  # El entorno de la maquina no manda en este fichero: las claves que estos
  # tests no ponen, no existen. Si quien corre la suite tiene
  # `CANDIL_API_KEYS` puesta, un test que arranca sin claves se quedaria
  # sirviendo y la suite no terminaria — y un test que cuelga por el entorno de
  # otro miente sobre lo que prueba.
  setup do
    previous = System.get_env(@api_keys_env)
    System.delete_env(@api_keys_env)

    on_exit(fn -> if previous, do: System.put_env(@api_keys_env, previous) end)

    :ok
  end

  # Un gateway arrancado se para al final del test, pase lo que pase.
  # `:shutdown` y no `:kill`: el listener sale sin log de crash, que es como
  # sale el que para un servidor.
  defp cleanup(%{pid: pid}) do
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    :ok
  end

  # `capture_io/1` devuelve lo que se imprimio, y el `info` —con el puerto de
  # verdad— se queda dentro. El `send` lo saca: es lo unico que el test necesita
  # de dentro de la captura.
  defp arrancar_capturando(opts) do
    salida =
      capture_io(fn ->
        {:ok, info} = Serve.start(opts)
        send(self(), {:gateway, info})
      end)

    assert_received {:gateway, info}
    cleanup(info)
    {salida, info}
  end

  defp http(method, url, headers \\ []) do
    case Finch.request(Finch.build(method, url, headers, nil), Finch) do
      {:ok, %Finch.Response{status: status, body: body}} -> {status, body}
      {:error, reason} -> flunk("no se pudo #{method} #{url}: #{inspect(reason)}")
    end
  end

  describe "la declaracion" do
    test "esta en el CLI, con sus flags en la ayuda" do
      assert "serve" in CLI.command_names()

      ayuda = capture_io(fn -> CLI.main(["serve", "--help"]) end)

      for flag <- ["--host", "--port", "--auth", "--api-key"] do
        assert ayuda =~ flag, "la ayuda de serve no menciona #{flag}"
      end
    end
  end

  describe "lo que no arranca" do
    test "un modo de auth que no existe: error, con el motivo, y sin listener" do
      salida = capture_io(fn -> assert CLI.main(["serve", "--auth", "oauth"]) == :error end)

      assert salida =~ ~s(auth must be "none" or "api_key")
      # El valor que se escribio, tal cual: sin eso el mensaje diria que hay un
      # modo malo pero no cual.
      assert salida =~ "oauth"
      refute salida =~ "** (", "un flag mal escrito no puede reventar"
    end

    test "auth api_key sin claves: lo dice y sale con error" do
      salida = capture_io(fn -> assert CLI.main(["serve", "--auth", "api_key"]) == :error end)

      assert salida =~ "needs at least one key"
    end
  end

  describe "el banner" do
    test "dice el puerto de verdad, no el cero que se pidio" do
      {salida, info} = arrancar_capturando(port: 0)

      assert info.port > 0
      assert salida =~ "http://127.0.0.1:#{info.port}/v1"
      assert salida =~ "escuchando"
      assert salida =~ "consumidores"
      assert salida =~ "Ctrl-C"
    end

    test "acepta las dos formas de opts: la lista de la biblioteca y el mapa de Alaja" do
      {_salida, desde_lista} = arrancar_capturando(port: 0)
      {_salida, desde_mapa} = arrancar_capturando(%{port: 0})

      assert desde_lista.port > 0
      assert desde_mapa.port > 0
    end

    test "sin auth lo dice, y un aviso si el puerto no es solo de esta maquina" do
      {salida, _info} = arrancar_capturando(host: "0.0.0.0", port: 0)

      assert salida =~ "ninguna"
      assert salida =~ "cualquiera que llegue a ese puerto"
    end

    test "con --api-key y auth = none, avisa de que la clave no se usa" do
      {salida, info} = arrancar_capturando(port: 0, api_key: ["sk-ignorada"])

      assert salida =~ "--api-key se ignora"

      # Y de verdad no se usa: sin `auth = api_key` no hay 401.
      {status, _body} = http(:get, "http://127.0.0.1:#{info.port}/metrics")

      assert status == 200
    end
  end

  describe "las claves" do
    test "del flag: 401 sin ella y 200 con ella, por el socket" do
      {salida, info} = arrancar_capturando(port: 0, auth: "api_key", api_key: ["sk-uno"])
      gw = "http://127.0.0.1:#{info.port}"

      assert salida =~ "api key"

      {status, body} = http(:get, gw <> "/metrics")
      assert status == 401
      assert body =~ "Authorization"

      {status, _body} = http(:get, gw <> "/metrics", [{"authorization", "Bearer sk-uno"}])
      assert status == 200
    end

    test "del entorno: separadas por comas, con espacios de sobra" do
      # Con espacios a proposito: `CANDIL_API_KEYS="sk-uno, sk-dos"` es como lo
      # escribe cualquiera, y una clave `" sk-dos"` no coincide con nada.
      System.put_env(@api_keys_env, "sk-uno, sk-dos")

      {_salida, info} = arrancar_capturando(port: 0, auth: "api_key")
      gw = "http://127.0.0.1:#{info.port}"

      {status, _body} = http(:get, gw <> "/metrics")
      assert status == 401

      {status, _body} = http(:get, gw <> "/metrics", [{"authorization", "Bearer sk-dos"}])
      assert status == 200
    end
  end

  describe "el «se queda»" do
    test "run/1 no vuelve, y cuando el proceso muere el puerto se cierra" do
      salida =
        capture_io(fn ->
          tarea = spawn(fn -> Serve.run(port: 0) end)

          # Si `run/1` volviera, el proceso estaria muerto. Se le da tiempo: lo
          # unico que tarda es el arranque de Bandit.
          Process.sleep(300)
          assert Process.alive?(tarea), "run/1 volvio en vez de quedarse sirviendo"

          # `:kill` y no `:shutdown`: `run/1` trapa las salidas —es lo que le
          # permite contar una caida del listener— y un `:shutdown` se queda en
          # la bandeja esperando a un `receive` que no lo mira. Medido: con
          # `:shutdown` el puerto seguia abierto cinco segundos despues; con
          # `:kill` (que no se puede trapar) el listener muere con el proceso.
          #
          # El cierre deja un log de error de ThousandIsland, y se recoge aqui
          # para que la suite no imprima el ruido de un servidor que se para a
          # proposito.
          cierre =
            capture_log(fn ->
              Process.exit(tarea, :kill)
              Process.sleep(200)
            end)

          assert cierre =~ "killed"
        end)

      assert [_, puerto] = Regex.run(~r{http://127\.0\.0\.1:(\d+)/v1}, salida)
      assert puerto_cerrado?(String.to_integer(puerto))
    end
  end

  # El listener esta enlazado al proceso que lo arranco: cuando ese muere, el
  # puerto se libera. Se pregunta al socket, que es la unica respuesta que
  # importa — un `Process.alive?/1` diria de un proceso, no del puerto.
  defp puerto_cerrado?(puerto, intentos \\ 20) do
    case :gen_tcp.connect(~c"127.0.0.1", puerto, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        if intentos > 0 do
          Process.sleep(50)
          puerto_cerrado?(puerto, intentos - 1)
        else
          false
        end

      {:error, _reason} ->
        true
    end
  end
end
