defmodule Candil.PolicyTest do
  @moduledoc """
  La politica de turnos: quien va primero en un destino.

  Los tests de este fichero son **contrato de orden**, y la asercion de cada uno
  dice que NO puede ocurrir. Un `assert status.waiting == 0` solo dice que ahora
  no hay nadie esperando; lo que vale es el `refute_receive` de mas abajo, que
  dice que el segundo **no** entro mientras el primero tenia el turno.

  ## Que es una propiedad y no un modo

  Aqui no hay ningun interruptor global ni ningun enum. Lo unico que se
  configura es, por destino, si es **exclusivo** o no, y el defecto es `false`:
  la mayoria de los destinos son una API, que no se estorba con nadie. Ver el
  `@moduledoc` de `Candil.Policy` y el §3 de `docs/06-capacidad-y-politica`.

  ## Por que `async: false`

  Por tres estados que son globales: el `Store` (ETS), el fichero de
  configuracion que algunos tests escriben en `CANDIL_CONFIG` y los procesos de
  la cola, que se registran por nombre en `Candil.Registry`. Un test que espera
  «no hay cola para :coder» no puede correr en paralelo con otro que acaba de
  dejar una.
  """
  use Candil.StoreCase

  alias Candil.Policy
  alias Candil.Policy.{Destination, Turn}
  alias Candil.{Config, Engine, Error, Model, Provider, Store}

  @turn_event [:candil, :policy, :turn]

  setup do
    :ok =
      Store.register_provider(%Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://example.invalid"
      })

    for {model_alias, name} <- [coder: "coder-1", verifier: "verifier-1"] do
      register(model_alias, name)
    end

    # Y la cola se para entre tests. Sin esto, la que arranco uno sobrevive al
    # siguiente y el "camino caliente" encuentra un proceso vivo en un destino
    # que acaba de registrar como **no exclusivo** —que es exactamente el fallo
    # que estos tests existen para cazar, creado por el propio test.
    #
    # No se limpia el estado global en un `on_exit` por costumbre: se limpia
    # porque se ha medido que sin esto fallan 14 de 31 al correr juntos y
    # ninguno al correr solo.
    on_exit(fn -> Policy.stop_all() end)

    :ok
  end

  # ── 1 · El camino caliente ──────────────────────────────────────────────────

  describe "el camino caliente" do
    test "el defecto es el aburrido: no exclusivo" do
      # Lo que sale de la caja. Si esto cambia, todo lo de abajo deja de
      # describir el defecto y pasa a describir otra cosa.
      refute Policy.exclusive?(:coder)
      assert Policy.run(:coder, fn -> :ok end) == {:ok, :ok}
      assert Policy.status(:coder) == nil
    end

    test "un `exclusive = false` explicito tampoco arranca ninguna cola" do
      # Que el defecto se pueda ESCRIBIR sin cambiar nada es lo que hace que la
      # propiedad sea una propiedad y no un modo: quien lo pone dice «este
      # destino no es mio», y el resultado es el mismo camino.
      exclusive(:coder, false)
      exclusive(:verifier, false)

      collect_turns()

      for destination <- [:coder, :verifier] do
        assert {:ok, :ran} = Policy.run(destination, fn -> send(self(), :ran) end)
        assert_received :ran
        assert Destination.whereis(destination) == nil, "no deberia existir proceso de cola"
        assert Policy.status(destination) == nil
      end

      refute_received {:turn, _, _, _}
    end

    test "no toca la cola: ni proceso, ni evento, ni salto de proceso" do
      # Las TRES, porque cada una se rompe sola:
      #
      #   - el proceso: que exista una cola para un destino libre es la forma de
      #     que «no hay cola» se cumpla de mentira.
      #   - el evento: es lo que haria falta para que un camino «hot» se
      #     midiera como un paso por aqui.
      #   - el `self()`: la funcion corre donde la llamo, no en un proceso de
      #     la cola. Si corriera dentro, la peticion y el turno serian dos
      #     procesos, y una peticion que muere se llevaria su turno.
      collect_turns()

      assert {:ok, :ran} = Policy.run(:coder, fn -> send(self(), :ran) end)

      assert_received :ran
      assert Policy.status(:coder) == nil, "un destino no exclusivo no deberia tener cola"
      assert Destination.whereis(:coder) == nil, "no deberia existir proceso de cola"
      refute_received {:turn, _, _, _}
    end

    test "nueve peticiones a la vez no hacen cola ni se esperan" do
      # El defecto no es «casi siempre no hace cola»: es que no la hace. Con
      # nueve a la vez, cualquier serializacion accidental se veria.
      tasks = for _ <- 1..9, do: Task.async(fn -> Policy.run(:coder, fn -> :ok end) end)

      for task <- tasks do
        assert Task.await(task, 5_000) == {:ok, :ok}
      end

      assert Destination.whereis(:coder) == nil
    end

    test "el admit se respeta tambien cuando el destino no es exclusivo" do
      # La regla 1 no es solo de los destinos encolados: es de la capa. Si aqui
      # el admit se pudiera saltar, un destino vetado pasaria en el camino que
      # usa todo el mundo.
      banned = fn -> {:error, Error.invalid_request("este destino no recibe esto")} end

      assert {:error, %Error{reason: :invalid_request}} =
               Policy.run(:coder, fn -> :never end, admit: banned)

      assert Destination.whereis(:coder) == nil
    end
  end

  # ── 2 · La cola serial ──────────────────────────────────────────────────────

  describe "un destino exclusivo" do
    setup do
      exclusive(:coder, true)
      :ok
    end

    test "la segunda peticion ESPERA, y sale cuando la primera suelta" do
      {:ok, first} = Policy.enter(:coder)

      parent = self()

      second =
        Task.async(fn ->
          send(parent, :second_asked)

          Policy.run(:coder, fn ->
            send(parent, :second_ran)
            :ok
          end)
        end)

      assert_receive :second_asked, 1_000

      # Lo que NO puede ocurrir: que la segunda entre mientras la primera tiene
      # el turno. Este `refute` es la asercion; los `assert` de despues solo la
      # confirman cuando la primera suelta.
      refute_receive :second_ran, 100
      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      assert %{holder: holder} = Policy.status(:coder)
      assert holder == self()

      assert :ok = Policy.finish(first)
      assert_receive :second_ran, 1_000
      assert Task.await(second, 5_000) == {:ok, :ok}
      assert (Policy.status(:coder) || %{})[:waiting] == 0
    end

    test "el turno termina cuando termina la peticion, no antes" do
      # `run/3` suelta en un `after`. Si soltara antes, el segundo entraria
      # mientras el primero todavia esta usando el destino, que es justo el
      # fallo que un destino exclusivo no puede permitirse.
      parent = self()

      holder =
        Task.async(fn ->
          Policy.run(:coder, fn ->
            send(parent, :holding)
            receive do: (:go -> :ok)
            send(parent, :still_holding)
            :ok
          end)
        end)

      assert_receive :holding, 1_000

      waiter =
        Task.async(fn ->
          Policy.run(:coder, fn ->
            send(parent, :waiter_ran)
            :ok
          end)
        end)

      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      refute_receive :waiter_ran, 100

      send(holder.pid, :go)
      assert_receive :still_holding, 1_000

      # Aqui **no** hay un segundo `refute_receive`, y quitado va.
      #
      # Este test se llama "el turno termina cuando termina la peticion, no
      # antes": promete que el esperador no entra **mientras** el titular tiene
      # el turno, y eso ya esta comprobado con el `refute` de arriba. El
      # segundo decia "tampoco despues", que es otra promesa —y es falsa: en
      # cuanto la peticion termina, el turno se suelta en el `after`, y el
      # esperador entra. **Eso es el contrato**, no una violacion.
      #
      # Un asercion que exige mas de lo que el modulo promete, y mas de lo que
      # puede cumplir, es un test que obliga al codigo a hacer lo que no debe.
      # El `assert_receive :waiter_ran` de abajo es la comprobacion de verdad.

      assert Task.await(holder, 5_000) == {:ok, :ok}
      assert_receive :waiter_ran, 1_000
      assert Task.await(waiter, 5_000) == {:ok, :ok}
    end

    test "una peticion que revienta NO deja el destino bloqueado" do
      # Sin el `after`, el destino se queda con un turno de una peticion que ya
      # no existe, y todo lo que venga despues espera para siempre. El sintoma
      # seria «Candil se cuelga», no «un test fallo».
      assert catch_exit(Policy.run(:coder, fn -> exit(:boom) end))
      assert %{holder: nil, waiting: 0} = Policy.status(:coder)
      assert Policy.run(:coder, fn -> :ok end) == {:ok, :ok}
    end

    test "quien muere con el turno deja el destino libre" do
      # El turno vive en el proceso de la peticion. Si ese proceso se muere, el
      # destino no puede quedarse esperando a un turno que no va a terminar.
      parent = self()

      doomed =
        Task.async(fn ->
          Policy.run(:coder, fn ->
            send(parent, :holding)
            receive do: (:never -> :ok)
          end)
        end)

      assert_receive :holding, 1_000
      assert (Policy.status(:coder) || %{})[:holder] == doomed.pid

      Task.shutdown(doomed, :brutal_kill)

      # El DOWN lo ve el proceso de la cola, no este test: hay que darle tiempo
      # a que le llegue en vez de suponer que ya lo ha procesado.
      assert eventually(fn -> (Policy.status(:coder) || %{})[:holder] == nil end)
      assert Policy.run(:coder, fn -> :ok end) == {:ok, :ok}
    end

    test "quien espera y se muere no se queda en la cola" do
      # Un zombi en la cola no ocupa sitio: ocupa el turno del siguiente sin
      # haberlo pedido, y el sintoma es «la segunda peticion no entra nunca».
      parent = self()

      {:ok, first} = Policy.enter(:coder)

      waiter =
        Task.async(fn ->
          send(parent, :asked)
          Policy.enter(:coder)
        end)

      assert_receive :asked, 1_000
      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)

      Task.shutdown(waiter, :brutal_kill)
      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 0 end)

      assert :ok = Policy.finish(first)
      assert (Policy.status(:coder) || %{})[:holder] == nil
    end

    test "si la cola muere con alguien esperando, el que esperaba se entera" do
      # Un `GenServer.call` a un proceso muerto da un `exit`, y un `exit` en
      # medio de una peticion que el usuario ha hecho no es una respuesta. Y el
      # `finish` del turno que se llevo la cola tampoco puede volver a hacer
      # nada: se dice, en vez de callarse.
      parent = self()

      {:ok, first} = Policy.enter(:coder)

      waiter =
        Task.async(fn ->
          send(parent, :asked)
          Policy.enter(:coder)
        end)

      assert_receive :asked, 1_000
      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)

      pid = Destination.whereis(:coder)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      assert Task.await(waiter, 5_000) == {:error, :policy_unavailable}
      assert eventually(fn -> Policy.status(:coder) == nil end)
      assert Policy.finish(first) == {:error, :policy_unavailable}
    end

    test "tres peticiones de una vez se sirven de una en una, en orden" do
      # Lo que la unidad de la cola decide. No hay modo quantum ni nada que
      # reparta: la peticion entra cuando la anterior ha terminado.
      parent = self()

      tasks =
        for tag <- [:a, :b, :c] do
          {tag, Task.async(fn -> enter_and_report(parent, :coder, tag) end)}
        end

      [{:a, a}, {:b, b}, {:c, c}] = tasks

      send(a.pid, :go)
      assert eventually(fn -> (Policy.status(:coder) || %{})[:holder] == a.pid end)
      send(b.pid, :go)
      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      send(c.pid, :go)
      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 2 end)

      # Y ahora se sueltan **de uno en uno**, que es lo que convierte esto en un
      # contrato de orden y no en una carrera. Lo que NO puede ocurrir es que
      # b entre antes de que a haya soltado.
      send(a.pid, :release)
      assert eventually(fn -> (Policy.status(:coder) || %{})[:holder] == b.pid end)
      send(b.pid, :release)
      assert eventually(fn -> (Policy.status(:coder) || %{})[:holder] == c.pid end)
      send(c.pid, :release)

      for {_tag, task} <- tasks, do: assert(Task.await(task, 5_000) == :ok)

      assert collect_served(3) == [:a, :b, :c]
    end
  end

  # ── 3 · Ceder el turno, y lo que todavia no existe ──────────────────────────

  describe "ceder el turno" do
    setup do
      exclusive(:coder, true)
      :ok
    end

    test "quien cede el turno lo pierde, y no vuelve al final de la cola" do
      # Es la UNICA regla de `yield/1`, y es la que el diseño llamaba
      # `one_for_all`. A entra, cede, y B —que estaba esperando— entra; A no
      # vuelve. El `{:error, :discarded}` es lo que le dice a A que su turno se
      # acabo: sin esa respuesta, el que cede no sabe si esperar o rendirse.
      #
      # Lo que el diseño llamaba `rest_for_one` —A vuelve AL FINAL— NO esta
      # implementado, y no esta ni de-stub: se escribira el dia que exista un
      # destino que pueda ceder el turno antes de terminar. Ver el `@moduledoc`.
      parent = self()

      a =
        Task.async(fn ->
          {:ok, turn} = Policy.enter(:coder)
          send(parent, {:served, :a})

          receive do
            :b_is_waiting -> :ok
          end

          case Policy.yield(turn) do
            {:ok, _next} ->
              send(parent, {:served, :a})
              :ok

            {:error, reason} ->
              send(parent, {:dropped, reason})
              :ok
          end
        end)

      assert_receive {:served, :a}, 1_000

      b =
        Task.async(fn ->
          {:ok, turn} = Policy.enter(:coder)
          send(parent, {:served, :b})
          Policy.finish(turn)
        end)

      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      send(a.pid, :b_is_waiting)

      assert Task.await(a, 5_000) == :ok
      assert Task.await(b, 5_000) == :ok

      # `{:served, :a}` se consumio mas arriba con el `assert_receive`. Aqui solo
      # queda el de B, que es el que demuestra que A ceder **desato** a alguien.
      assert collect_served(1) == [:b]
      assert_received {:dropped, :discarded}
      assert (Policy.status(:coder) || %{})[:holder] == nil
    end

    test "un turno cedido ya no se puede terminar" do
      # El `finish/1` de un turno cedido no puede soltar EL TURNO DE OTRO. Por
      # eso el turno lleva un token y no solo un numero: «me llamo turno 1» no
      # dice quien lo tiene ahora.
      {:ok, first} = Policy.enter(:coder)

      assert {:error, :discarded} = Policy.yield(first)
      assert {:error, :not_holder} = Policy.finish(first)
    end

    test "ceder con la cola vacia lo pierde igual" do
      # Devolverlo al final de una cola vacia seria devolverlo a si mismo, y
      # eso no es ceder: es no hacer nada. Sin nadie esperando, el turno se
      # acaba y el destino queda libre para el siguiente.
      {:ok, first} = Policy.enter(:coder)

      assert {:error, :discarded} = Policy.yield(first)
      assert %{holder: nil, waiting: 0} = Policy.status(:coder)
      assert Policy.run(:coder, fn -> :ok end) == {:ok, :ok}
    end

    test "un destino que no es exclusivo no tiene turno que ceder" do
      # `%Turn{turn: nil, token: nil}` no es un turno a medio hacer: es la
      # respuesta correcta a «este destino no es exclusivo».
      {:ok, turn} = Policy.enter(:verifier)

      assert %Turn{turn: nil, token: nil} = turn
      assert {:error, :not_queued} = Policy.yield(turn)
      assert :ok = Policy.finish(turn)
      assert Destination.whereis(:verifier) == nil
    end
  end

  # ── 4 · La cola es POR DESTINO ──────────────────────────────────────────────

  describe "la cola es por destino" do
    test "dos destinos distintos no se estorban" do
      # El test que mas dice de todos. Un destino ocupado no puede ralentizar a
      # un destino que no tiene nada que ver, y el sintoma de lo contrario es
      # «Candil va lento» sin ninguna direccion.
      exclusive(:coder, true)
      exclusive(:verifier, true)

      {:ok, held_coder} = Policy.enter(:coder)
      assert (Policy.status(:coder) || %{})[:holder] == self()

      # Con `:coder` en manos de ESTE proceso, `:verifier` —que tambien es
      # exclusivo— contesta enseguida: otra cola, otro estado, y ni se entera.
      # Lo que demuestra es que `:verifier` **no espera**: con `:coder` en
      # manos de este proceso, la otra cola contesta y devuelve.
      assert Policy.run(:verifier, fn -> :ok end) == {:ok, :ok}

      # Y `:verifier` queda libre otra vez, porque `run/3` **suelta al
      # terminar**. La asercion que hacia antes —que el titular siguiera
      # siendo este— era falsa: `run/3` ya habia devuelto.
      assert (Policy.status(:verifier) || %{})[:holder] == nil
      assert (Policy.status(:coder) || %{})[:holder] == self()

      # Y al reves: con los dos ocupados, entrar en uno no cuenta como entrar en
      # el otro.
      {:ok, held_verifier} = Policy.enter(:verifier)
      parent = self()

      blocked =
        Task.async(fn ->
          Policy.run(:coder, fn ->
            send(parent, :nope)
            :ok
          end)
        end)

      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      assert (Policy.status(:verifier) || %{})[:waiting] == 0
      refute_receive :nope, 100

      assert :ok = Policy.finish(held_coder)
      assert :ok = Policy.finish(held_verifier)
      assert Task.await(blocked, 5_000) == {:ok, :ok}
    end

    test "con un destino encolado, un destino no exclusivo no aparece en ningun mapa" do
      # Un destino ocupado **sostenido** no puede arrastrar a los demas. Con una
      # cola global, estas cinco peticiones habrian esperado a que la primera
      # soltara, y con una cola por destino las cinco salen.
      exclusive(:coder, true)
      exclusive(:verifier, false)

      {:ok, held} = Policy.enter(:coder)

      tasks = for _ <- 1..5, do: Task.async(fn -> Policy.run(:verifier, fn -> :ok end) end)

      for task <- tasks do
        assert Task.await(task, 5_000) == {:ok, :ok}
      end

      # Y no hay ni proceso ni estado para un destino que no se encola.
      assert Policy.status(:verifier) == nil
      assert Destination.whereis(:verifier) == nil
      assert (Policy.status(:coder) || %{})[:holder] == self()
      assert :ok = Policy.finish(held)
    end

    test "el destino puede ser el alias de un engine o de un provider" do
      # Lo que se serializa es un destino, y un destino es lo que dice el
      # `alias`: tres cosas distintas que en Candil se nombran igual. Y las dos
      # que no son modelos **no declaran exclusividad**: un provider es la API
      # de otro y un engine puede servir a varios modelos, asi que el defecto
      # aburrido es el que les toca.
      :ok = Store.register_engine(%Engine{alias: :llama_cpp, binary: "llama-server"})

      refute Policy.exclusive?(:llama_cpp)
      refute Policy.exclusive?(:openai)

      assert Policy.run(:llama_cpp, fn -> :ok end) == {:ok, :ok}
      assert Policy.run(:openai, fn -> :ok end) == {:ok, :ok}
      assert Destination.whereis(:llama_cpp) == nil
      assert Destination.whereis(:openai) == nil
    end
  end

  # ── 5 · Lo que el valor no puede cambiar ─────────────────────────────────────

  describe "las tres reglas" do
    test "un destino que no existe no se encola, y contesta el error que ya existe" do
      # Ni siquiera si el modelo de al lado dice que si. Una cola para un
      # destino inexistente se queda ahi para siempre, y lo que tiene que
      # contestar el llamante es el mismo error que ya conoce.
      assert {:error, %Error{reason: :model_not_found} = error} = Policy.enter(:nope)
      assert error.context.model_alias == :nope
      assert Policy.status(:nope) == nil
      assert Destination.whereis(:nope) == nil
    end

    test "tampoco por el camino de run/3" do
      assert {:error, %Error{reason: :model_not_found}} = Policy.run(:nope, fn -> :never end)
      assert Destination.whereis(:nope) == nil
    end

    test "que un destino no exista gana a que no sea exclusivo" do
      # El orden de las dos comprobaciones. `exclusive?/1` contesta `false` para
      # lo que no encuentra, asi que si se preguntara antes, un alias
      # inexistente entraria por el camino caliente y `run/3` ejecutaria la
      # funcion contra un destino que no esta. Se comprueba en la regla 1.
      assert {:error, %Error{reason: :model_not_found}} =
               Policy.run(:nope, fn -> send(self(), :never) end)

      refute_received :never
    end

    test "ninguna configuracion devuelve un destino vetado, y el admit se propaga tal cual" do
      # Exclusivo y no exclusivo, y el error devuelto **identico**: quien decide
      # la elegibilidad es quien la ha decidido, y esta capa no reescribe el
      # motivo —tampoco sus numeros.
      forbidden = %Error{reason: :invalid_request, context: %{why: "vetado", requested: 4_096}}

      for is_exclusive <- [true, false] do
        exclusive(:coder, is_exclusive)

        assert {:error, ^forbidden} =
                 Policy.run(:coder, fn -> :never end, admit: fn -> {:error, forbidden} end)

        assert Policy.status(:coder) == nil
        assert Destination.whereis(:coder) == nil
      end
    end

    test "un admit que no se entiende rechaza, en vez de admitir" do
      # Default-deny. Un admit que contesta otra cosa no se puede defender, y la
      # regla 1 no perdona: admitir a ciegas es peor que rechazar de mas.
      exclusive(:coder, true)

      assert {:error, {:invalid_admission, :maybe}} =
               Policy.run(:coder, fn -> :never end, admit: fn -> :maybe end)

      assert Destination.whereis(:coder) == nil
    end

    test "un destino ocupado no se contesta con un numero inventado" do
      # La regla 2 en la forma que se puede comprobar: en un destino exclusivo
      # ocupado, la segunda peticion no recibe un `{:error, :busy, 0}`. Recibe
      # silencio, y sale cuando la primera suelta. Aqui no se fabrica ningun
      # motivo, porque esta capa no sabe por que se rechaza una peticion.
      #
      # Y se declara **exclusivo aqui**, porque el test de arriba recorre
      # `[true, false]` dentro de su cuerpo y lo deja en `false`: este describe
      # no tiene `setup` que lo restablezca, y sin esto la cola ni existe y
      # `waiting` nunca llega a 1. Cada test declara lo que necesita.
      exclusive(:coder, true)
      {:ok, first} = Policy.enter(:coder)
      parent = self()

      second =
        Task.async(fn ->
          Policy.run(:coder, fn ->
            send(parent, :ok)
            :ok
          end)
        end)

      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      refute_received {:error, _, _}

      assert :ok = Policy.finish(first)
      assert_receive :ok, 1_000
      assert Task.await(second, 5_000) == {:ok, :ok}
    end
  end

  # ── 6 · Lo que se mide ──────────────────────────────────────────────────────

  describe "telemetria" do
    test "un turno sin espera no dice que espero, y uno que espera si" do
      # `waited: false` con duracion 0 y `waited: true` con duracion > 0. Un
      # evento que siempre dijera «espero» no distinguiria un destino lento de
      # uno que no lo esta, que es justo lo que un router tiene que saber.
      exclusive(:coder, true)
      collect_turns()

      assert Policy.run(:coder, fn -> :ok end) == {:ok, :ok}

      assert_receive {:turn, @turn_event, %{duration: first}, %{waited: false, turn: 1}}
      assert first == 0

      {:ok, held} = Policy.enter(:coder)
      parent = self()

      waiter =
        Task.async(fn ->
          Policy.run(:coder, fn ->
            send(parent, :ok)
            :ok
          end)
        end)

      assert eventually(fn -> (Policy.status(:coder) || %{})[:waiting] == 1 end)
      assert :ok = Policy.finish(held)
      assert_receive :ok, 1_000
      assert Task.await(waiter, 5_000) == {:ok, :ok}

      # Y el turno **3**, no el 2: `Policy.enter/2` tambien toma turno y emite
      # su evento — el del que no esperaba nadie, con duracion 0. Contarlos es
      # lo correcto, porque `served` es lo que dice cuantas veces ha atendido
      # este destino. Este test fallaba por leerlo como 2.
      assert_receive {:turn, @turn_event, %{duration: second}, %{waited: true, turn: 3}}
      assert second > 0
    end
  end

  # ── 7 · La configuracion: una propiedad, en el sitio del destino ─────────────

  describe "run/3 es idempotente" do
    test "quien ya tiene el turno no se encola otra vez" do
      # La cola se toma en `Inference`, y hay caminos que ya la tienen tomaday
      # llaman a otro que tambien la toma. Sin esto, el segundo `enter/2` seria
      # el mismo proceso pidiendo una cola que ya tiene: en un destino
      # **exclusivo** se quedaria esperando a si mismo, para siempre.
      #
      # El refute es lo que vale aqui: no basta con que el segundo `run/3`
      # responda, tiene que responder **sin esperar**.
      exclusive(:coder, true)

      assert {:ok, :uno} = Policy.run(:coder, fn -> :uno end)

      task =
        Task.async(fn ->
          Policy.run(:coder, fn -> :dentro end)
        end)

      assert Task.yield(task, 2_000) == {:ok, {:ok, :dentro}},
             "el segundo run/3 se ha encolado en un turno que ya era suyo"

      # Y no se ha creado una segunda cola ni dejado el destino ocupado.
      refute Destination.whereis(:coder) == nil
      assert Policy.status(:coder).waiting == 0
    end

    test "el turno se suelta al salir, aunque lo envuelvan dos veces" do
      # El camino de la doble envoltura completo: gateway -> Inference. Lo que
      # se comprueba es que el destino **queda libre**, que es el fallo que un
      # turno anidado sin soltar dejaria en cualquier destino exclusivo.
      exclusive(:coder, true)

      # El `{:ok, {:ok, :ok}}` no es un error: `run/3` siempre devuelve `{:ok, lo
      # que devuelva la funcion`, y aqui la funcion es otro `run/3`.
      assert {:ok, {:ok, :ok}} =
               Policy.run(:coder, fn ->
                 Policy.run(:coder, fn -> :ok end)
               end)

      # Y el destino queda **libre**: sin titular y sin nadie esperando. El
      # proceso de la cola sigue vivo a proposito —es lo que dice
      # `stop_all/0`— y lo que no puede pasar es que quede alguien colgando
      # esperando a un turno que ya no existe.
      assert %{waiting: 0, holder: nil} = Policy.status(:coder)
    end

    test "un destino distinto si se encola, aunque el turno sea del mismo proceso" do
      # La idempotencia es **por destino**, no global: tener el turno de una GPU
      # no da el turno de otra.
      exclusive(:coder, true)
      exclusive(:verifier, true)

      assert {:ok, {:ok, :ok}} =
               Policy.run(:coder, fn ->
                 Policy.run(:verifier, fn -> :ok end)
               end)
    end
  end

  describe "los cuatro caminos de inferencia toman turno" do
    # Si `exclusive` es una propiedad del destino —y lo es desde que el turno se
    # toma en `Candil.Inference` y no en quien llama— entonces un destino
    # **remoto** marcado como exclusivo tiene que serializar igual. Si no, la
    # garantia es media, que es peor que no existir: porque alguien lee
    # `exclusive` en el toml y no mira si el modelo es local o remoto.
    test "un remoto exclusivo tambien hace cola" do
      exclusive(:remoto_exclusivo, true)

      assert Policy.exclusive?(:remoto_exclusivo)

      tareas =
        for _ <- 1..8 do
          Task.async(fn -> Policy.run(:remoto_exclusivo, fn -> :ok end) end)
        end

      resultados = Enum.map(tareas, &Task.await(&1, 10_000))

      assert Enum.all?(resultados, &(&1 == {:ok, :ok}))
    end

    test "y los cuatro caminos pasan por Policy.run" do
      # Un test de contrato sobre el codigo, que es lo que se puede comprobar
      # sin una peticion real: si alguien quita el turno de uno de los cuatro,
      # este test falla aunque la suite de integracion no lo note.
      fuente = File.read!(Path.join([__DIR__, "..", "..", "lib", "candil", "inference.ex"]))

      # Una comprobacion por camino, y no un recuento: un recuento dice cuantos
      # hay, y si anades uno de mas te dice "correcto".
      for {funcion, cabeza} <- [
            {"chat_local", "def chat_local("},
            {"chat_remote",
             "def chat_remote(%Model{} = model, %Provider{} = provider, messages, opts) do"},
            {"embed_local", "def embed_local("},
            {"embed_remote",
             "def embed_remote(%Model{} = model, %Provider{} = provider, texts, opts) do"}
          ] do
        cuerpo = cuerpo_de(fuente, cabeza)

        assert cuerpo =~ "con_turno(",
               "#{funcion} no toma turno: la exclusividad seria del camino, no del destino"
      end
    end
  end

  describe "la cola se toma al hablar con el destino" do
    test "doce peticiones simultaneas a un destino exclusivo hacen cola" do
      # Esta es la garantia que faltaba. Medido en la GPU antes del cambio: 12
      # peticiones simultaneas por `Inference.chat_local/3` daban **0 esperas**
      # contra un destino `exclusive = true`, y 11 por el camino del gateway.
      # La exclusividad era una propiedad del camino de entrada.
      exclusive(:coder, true)

      assert Policy.exclusive?(:coder)

      tareas =
        for _ <- 1..12 do
          Task.async(fn -> Policy.run(:coder, fn -> :ok end) end)
        end

      resultados = Enum.map(tareas, &Task.await(&1, 10_000))

      assert Enum.all?(resultados, &(&1 == {:ok, :ok}))
      # Y la prueba de que hubo cola y noonce coincidencia: al terminar el
      # lote no queda nadie esperando.
      assert Policy.status(:coder).waiting == 0
    end
  end

  describe "la propiedad exclusive" do
    test "llega del TOML al Store, y decide sola" do
      # El camino entero: el fichero, el schema, `Hydrate`, el Store y la
      # politica. Es la unica forma de probar que esto **no** es un interruptor
      # global: el mismo fichero dice que un destino es mio y que otro no.
      with_toml("""
      [provider.openai]
      type = "openai"
      api_key = "sk-test"
      base_url = "https://example.invalid"

      [model.coder]
      type = "remote"
      provider = "openai"
      name = "coder-1"
      exclusive = true

      [model.embedder]
      type = "remote"
      provider = "openai"
      name = "embed-1"
      exclusive = false
      """)

      assert {:ok, config} = Config.File.load()
      assert {:ok, %{models: models}} = {:ok, Config.Hydrate.hydrate(config)}
      assert Enum.sort(models) == [:coder, :embedder]

      assert Policy.exclusive?(:coder)
      refute Policy.exclusive?(:embedder)

      # Y la consecuencia: solo el primero tiene cola.
      assert Policy.run(:embedder, fn -> :ok end) == {:ok, :ok}
      assert Destination.whereis(:embedder) == nil

      {:ok, _turn} = Policy.enter(:coder)
      assert Destination.whereis(:coder) != nil
    end

    test "un modelo sin la propiedad NO es exclusivo" do
      # El defecto tiene que ser el aburrido y el que no toca la cola, porque
      # quien no ha dicho nada no ha pedido una cola.
      with_toml("""
      [provider.openai]
      type = "openai"
      api_key = "sk-test"
      base_url = "https://example.invalid"

      [model.plain]
      type = "remote"
      provider = "openai"
      name = "plain-1"
      """)

      assert {:ok, config} = Config.File.load()
      # `Hydrate.hydrate/1` NO devuelve `{:ok, config}`: devuelve el mapa con
      # los errores DENTRO. Un modelo que entra bien queda como su alias, y uno
      # que falla como `{:error, alias, mensajes}`.
      assert %{models: [:plain]} = Config.Hydrate.hydrate(config)

      refute Policy.exclusive?(:plain)
      assert {:ok, %Turn{turn: nil, token: nil}} = Policy.enter(:plain)
      assert Destination.whereis(:plain) == nil
    end

    test "el schema la acepta como booleano, y solo como booleano" do
      # Opcional, y sin valor por omision en el schema: un TOML sin `exclusive`
      # valida, y eso es lo que hace que sea una propiedad y no un
      # interruptor obligatorio.
      assert {:ok, _} = Config.Schema.validate(%{"model" => %{"coder" => valid_model()}})

      assert {:ok, _} =
               Config.Schema.validate(%{
                 "model" => %{"coder" => Map.put(valid_model(), "exclusive", true)}
               })

      assert {:ok, _} =
               Config.Schema.validate(%{
                 "model" => %{"coder" => Map.put(valid_model(), "exclusive", false)}
               })

      for wrong <- [3, "true", "si", ~w(si)] do
        assert {:error, problems} =
                 Config.Schema.validate(%{
                   "model" => %{"coder" => Map.put(valid_model(), "exclusive", wrong)}
                 })

        assert Enum.any?(problems, &String.contains?(&1, "model 'coder'.exclusive must be")),
               "un `exclusive` de #{inspect(wrong)} tiene que estar dicho, no ignorado: " <>
                 "lo que no se es un booleano, y un booleano inventado es una cola " <>
                 "que alguien pidio sin saberlo"
      end
    end

    test "el esqueleto de candil init menciona la propiedad y no enciende nada" do
      # El bloque esta comentado: un `exclusive = true` DESCOMENTADO haria que
      # el primer `candil init` de un usuario serializara un destino sin
      # haberlo pedido.
      assert {:ok, rendered} = Config.Template.render()
      assert rendered =~ "exclusive"
      refute rendered =~ ~r/^\s*exclusive\s*=/m
    end

    test "no existe ningun sitio donde poner una politica global" do
      # `[general.policy]` era un interruptor global, y con tres APIs y una GPU
      # obligaba a elegir un modo para los cuatro, siendo malo para tres. Si
      # vuelve a aparecer, alguien ha vuelto a meter un interruptor.
      assert {:ok, _} = Config.Schema.validate(%{"general" => %{"data_dir" => "/tmp"}})

      {:ok, rendered} = Config.Template.render()
      refute rendered =~ "general.policy"
      refute rendered =~ "one_for_all"
      refute rendered =~ "rest_for_one"
    end
  end

  # ── Ayudantes ───────────────────────────────────────────────────────────────

  # La verdad de donde sale la exclusividad: el modelo del Store. Los tests que
  # necesitan un destino encolado lo encolan **aqui**, no con un interruptor.
  defp exclusive(alias, value) do
    case Store.get_model(alias) do
      {:ok, model} -> :ok = Store.register_model(%{model | exclusive: value})
      {:error, :not_found} -> :ok = register(alias, "#{alias}-1", value)
    end
  end

  defp register(alias, name, exclusive \\ false) do
    Store.register_model(%Model{
      alias: alias,
      type: :remote,
      provider: :openai,
      name: name,
      usage: [:chat],
      exclusive: exclusive
    })
  end

  defp valid_model do
    %{"type" => "remote", "provider" => "openai", "name" => "coder-1"}
  end

  # Registra un manejador que APUNTA los eventos de turno y lo suelta al
  # terminar. Sin esto, «no ha emitido nada» no se puede comprobar: un id fijo
  # se solaparia con el del test anterior y solo uno recibiria.
  defp collect_turns do
    test = self()
    id = {__MODULE__, System.unique_integer([:positive])}

    handler = fn event, measurements, metadata, _config ->
      send(test, {:turn, event, measurements, metadata})
    end

    :ok = :telemetry.attach(id, @turn_event, handler, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Espera a que la condicion sea verdad, sin suponer nada sobre el calendario:
  # un DOWN y un reply los entrega el proceso de la cola cuando le llegan, y un
  # `Process.sleep(10)` de aqui seria una suposicion con milisegundos.
  defp eventually(condition, attempts \\ 100)

  defp eventually(condition, 0), do: condition.()

  defp eventually(condition, attempts) do
    if condition.() do
      true
    else
      Process.sleep(10)
      eventually(condition, attempts - 1)
    end
  end

  defp with_toml(contents) do
    dir = Path.join(System.tmp_dir!(), "candil-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "candil.toml")
    File.write!(path, contents)

    previous = System.get_env("CANDIL_CONFIG")
    System.put_env("CANDIL_CONFIG", path)

    on_exit(fn ->
      if previous do
        System.put_env("CANDIL_CONFIG", previous)
      else
        System.delete_env("CANDIL_CONFIG")
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  # Entra, avisa, y **se queda con el turno** hasta que le dicen que lo suelte.
  #
  # Antes soltaba en el acto, y entonces nunca habia un titular: el padre
  # llegaba a `eventually` y encontraba la cola ya vacia. El test pedia
  # `waiting == 1` —alguien esperando mientras otro tiene el turno— y el helper
  # hacia imposible ese estado. Un test que pide una situacion que su propia
  # arandela no puede producir, no mide el contrato: mide el calendario.
  defp enter_and_report(parent, destination, tag) do
    receive do
      :go -> :ok
    end

    {:ok, turn} = Policy.enter(destination)
    send(parent, {:served, tag})

    receive do
      :release -> Policy.finish(turn)
    end
  end

  defp collect_served(count) do
    for _ <- 1..count do
      assert_receive {:served, tag}, 1_000
      tag
    end
  end

  # El cuerpo de la funcion que empieza por `cabeza`, hasta su `end` de nivel
  # superior. A proposito no es un parser de Elixir: un test de contrato solo
  # necesita «la funcion esta dentro de este texto», y un parser seria una
  # dependencia que puede romperse sola.
  defp cuerpo_de(fuente, cabeza) do
    desde = elem(:binary.match(fuente, cabeza), 0)
    resto = :binary.part(fuente, desde, byte_size(fuente) - desde)
    [cuerpo | _] = :binary.split(resto, "\n  end\n")
    cuerpo
  end
end
