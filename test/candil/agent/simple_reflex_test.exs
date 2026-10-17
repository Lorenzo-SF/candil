defmodule Candil.Agents.SimpleReflexTest do
  @moduledoc """
  El tipo 1: estímulo -> respuesta, sin memoria, y sin colgarse cuando el
  backend se cuelga.

  ## Por qué este test existe

  La F5.3 (`docs/04-modulos/05-agentes` §5.3) trae el primer `GenServer` de
  verdad. Del boceto del documento viven aquí los que de verdad quedaron, y el
  del cuelgue es la **puerta propia de la fase** (§6): ninguna de las siete
  puertas lo detecta, porque todas terminan cuando el proceso termina.
  """

  use ExUnit.Case, async: false

  alias Candil.Agents.SimpleReflex
  alias Candil.Agents.Supervisor, as: AgentsSupervisor

  # ── Tres backends de mentira, uno por caso ──────────────────────────────

  defmodule EchoBackend do
    @moduledoc """
    Contesta con lo que le llega —`FINAL_ANSWER: <último mensaje>`— y avisa al
    observador de qué mensajes vio. El observador es opcional, en
    `:persistent_term`, como el de `Candil.AgentTest.StubBackend`.
    """

    def chat(_model, messages, _opts) do
      if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
        send(observer, {:chat_messages, messages})
      end

      content = messages |> List.last() |> Map.fetch!(:content)

      {:ok,
       %{
         content: "FINAL_ANSWER: #{content}",
         finish_reason: "stop",
         usage: %{input_tokens: 0, output_tokens: 0}
       }}
    end
  end

  defmodule HangingBackend do
    @moduledoc "Se queda dentro para siempre: el backend que se cuelga (§8.3)."

    def chat(_model, _messages, _opts), do: Process.sleep(:infinity)
  end

  defmodule ExplodingBackend do
    @moduledoc "Revienta: un fallo de programación, no un error del motor."

    def chat(_model, _messages, _opts), do: raise("el backend revienta")
  end

  defmodule FlakyBackend do
    @moduledoc """
    Se cuelga mientras el interruptor está puesto y contesta cuando el test lo
    quita: el backend que se **endereza**, para la sonda del §8.3.
    """

    def chat(_model, _messages, _opts) do
      if :persistent_term.get({__MODULE__, :colgado?}, true) do
        Process.sleep(:infinity)
      else
        {:ok,
         %{
           content: "FINAL_ANSWER: ya",
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }}
      end
    end
  end

  setup do
    :persistent_term.put({EchoBackend, :observer}, self())
    on_exit(fn -> :persistent_term.erase({EchoBackend, :observer}) end)

    # El supervisor de agentes vive en el árbol de la aplicación desde la
    # F5.3: aquí no se arranca, se deja limpio. Si un test deja un hijo (o su
    # aserción falla antes de pararlo), el siguiente test lo encuentra.
    on_exit(fn ->
      for {_, pid, _, _} <- AgentsSupervisor.list_agents(), is_pid(pid) do
        AgentsSupervisor.stop_agent(pid)
      end
    end)

    :ok
  end

  describe "el tipo 1: estímulo -> respuesta (F5.3)" do
    test "responde al estímulo, y no se acuerda de nada entre llamadas" do
      pid =
        start_supervised!(
          {SimpleReflex, name: "router", goal: "clasificar", backend: EchoBackend}
        )

      assert {:ok, "uno", []} = SimpleReflex.evaluate(pid, "uno")

      assert_received {:chat_messages, primera}

      assert primera == [
               %{role: "system", content: "clasificar"},
               %{role: "user", content: "uno"}
             ]

      assert {:ok, "dos", []} = SimpleReflex.evaluate(pid, "dos")

      assert_received {:chat_messages, segunda}

      # La segunda llamada no ve la primera. Sin memoria, de verdad: la traza
      # vacía también lo dice — un reflejo de una vuelta no acumula pasos.
      assert segunda == [
               %{role: "system", content: "clasificar"},
               %{role: "user", content: "dos"}
             ]

      refute Enum.any?(segunda, &(&1[:content] == "uno"))
    end

    test "status/1 cuenta la configuración — y el circuito, que sigue cerrado tras una vuelta buena" do
      pid =
        start_supervised!(
          {SimpleReflex, name: "router", goal: "clasificar", backend: EchoBackend}
        )

      esperado = %{
        name: "router",
        goal: "clasificar",
        backend: EchoBackend,
        model: "default",
        max_steps: 1,
        timeout: 60_000,
        breaker: :closed
      }

      assert SimpleReflex.status(pid) == esperado

      assert {:ok, "uno", []} = SimpleReflex.evaluate(pid, "uno")

      # Después de trabajar, exactamente lo mismo: no acumula nada — y una
      # vuelta que contesta deja el circuito como estaba.
      assert SimpleReflex.status(pid) == esperado
    end

    test "un pin que no está en el catálogo es un error ruidoso, y el proceso sigue" do
      pid =
        start_supervised!({SimpleReflex, goal: "g", backend: EchoBackend, model: "inventado"})

      assert {:error, {:model_not_up, "inventado"}, []} = SimpleReflex.evaluate(pid, "hola")

      # El error viajó como dato: el agente no se cayó.
      assert %{model: "inventado"} = SimpleReflex.status(pid)
    end

    test "sin :backend no arranca" do
      assert {:error, :no_backend} = SimpleReflex.start_link(name: "x", goal: "y")
    end
  end

  describe "el cuelgue, el reinicio y el child spec (§8.3)" do
    @tag timeout: 2_000
    test "el backend que no vuelve no cuelga ni al agente ni a quien llama" do
      name = "colgado-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Agents.Breakers.forget(name) end)

      pid =
        start_supervised!(
          {SimpleReflex, name: name, goal: "g", backend: HangingBackend, timeout: 100}
        )

      # El plazo vive dentro: quien llama recibe el error, no un cuelgue. El
      # plazo es corto a propósito; si el agente se colgara de verdad, el
      # `@tag timeout:` de arriba corta el test en 2 s en vez de agotar el
      # timeout global (60 s).
      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "hola")

      # El plazo mató la llamada, no al agente: sigue vivo y sirviendo.
      assert %{name: ^name} = SimpleReflex.status(pid)
      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "otra vez")
    end

    @tag timeout: 5_000
    test "cinco cuelgues seguidos abren el circuito, y el sexto no paga el plazo" do
      name = "colgado-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Agents.Breakers.forget(name) end)

      pid =
        start_supervised!(
          {SimpleReflex, name: name, goal: "g", backend: HangingBackend, timeout: 50}
        )

      # Cinco vueltas, cinco plazos: cada una paga su plazo y contesta igual.
      for _ <- 1..5 do
        assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "hola")
      end

      assert %{breaker: :open} = SimpleReflex.status(pid)

      # La sexta no vuelve a pagar el plazo: el circuito contesta en el acto,
      # y dice con quién se cerró.
      t0 = System.monotonic_time(:millisecond)

      assert {:error, {:agent_circuit_open, ^name}, []} = SimpleReflex.evaluate(pid, "hola")

      assert System.monotonic_time(:millisecond) - t0 < 50
    end

    @tag timeout: 5_000
    test "la sonda de después del enfriamiento cierra el circuito si el backend se endereza" do
      :persistent_term.put({FlakyBackend, :colgado?}, true)
      on_exit(fn -> :persistent_term.erase({FlakyBackend, :colgado?}) end)
      on_exit(fn -> Candil.Agents.Breakers.forget("fugaz") end)

      pid =
        start_supervised!(
          {SimpleReflex,
           name: "fugaz",
           goal: "g",
           backend: FlakyBackend,
           timeout: 50,
           breaker_threshold: 2,
           breaker_cooldown_ms: 20}
        )

      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "uno")
      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "dos")
      assert %{breaker: :open} = SimpleReflex.status(pid)

      # Se endereza y pasa el enfriamiento: la sonda corre de verdad y, como
      # contesta, el circuito cierra.
      :persistent_term.put({FlakyBackend, :colgado?}, false)
      assert wait_until(fn -> SimpleReflex.status(pid).breaker == :probe end)

      assert {:ok, "ya", []} = SimpleReflex.evaluate(pid, "tres")
      assert %{breaker: :closed} = SimpleReflex.status(pid)
    end

    @tag timeout: 5_000
    test "el circuito abierto sobrevive al reinicio del agente", _ctx do
      name = "sobrevive-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Agents.Breakers.forget(name) end)

      pid =
        start_supervised!(
          {SimpleReflex,
           name: name, goal: "g", backend: HangingBackend, timeout: 50, breaker_threshold: 2}
        )

      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "uno")
      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "dos")
      assert %{breaker: :open} = SimpleReflex.status(pid)

      Process.exit(pid, :kill)

      assert wait_until(fn ->
               p = Candil.Agents.whereis(name)
               is_pid(p) and p != pid
             end)

      new_pid = Candil.Agents.whereis(name)

      assert %{breaker: :open} = SimpleReflex.status(new_pid)

      t0 = System.monotonic_time(:millisecond)

      assert {:error, {:agent_circuit_open, ^name}, []} =
               SimpleReflex.evaluate(new_pid, "tres")

      assert System.monotonic_time(:millisecond) - t0 < 50
    end

    test "un run que revienta se lleva al agente, y el supervisor lo levanta" do
      name = "terco-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Agents.Crashes.forget(name) end)

      {:ok, pid} =
        AgentsSupervisor.start_agent(SimpleReflex,
          name: name,
          goal: "g",
          backend: ExplodingBackend
        )

      # La llamada muere con el agente: el llamante ve un exit, no un cuelgue.
      assert {{%RuntimeError{message: "el backend revienta"}, _}, {GenServer, :call, _}} =
               catch_exit(SimpleReflex.evaluate(pid, "hola"))

      # Y el supervisor, que lo tenía en :permanent, lo vuelve a levantar.
      assert wait_until(fn ->
               AgentsSupervisor.list_agents()
               |> Enum.any?(fn {_, p, _, _} -> is_pid(p) and p != pid end)
             end)
    end

    test "un crash se registra en el presupuesto del agente" do
      name = "terco-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Agents.Crashes.forget(name) end)

      {:ok, pid} =
        AgentsSupervisor.start_agent(SimpleReflex,
          name: name,
          goal: "g",
          backend: ExplodingBackend
        )

      assert {{%RuntimeError{message: "el backend revienta"}, _}, {GenServer, :call, _}} =
               catch_exit(SimpleReflex.evaluate(pid, "hola"))

      # El crash quedó registrado: el presupuesto por agente no muere con
      # el proceso, que es la diferencia con la intensidad del supervisor.
      assert wait_until(fn ->
               Candil.Agents.Crashes.count(name, System.monotonic_time(:millisecond)) >= 1
             end)
    end

    test "el presupuesto agotado impide arrancar al agente" do
      name = "agotado-#{System.unique_integer([:positive])}"
      on_exit(fn -> Candil.Agents.Crashes.forget(name) end)

      now = System.monotonic_time(:millisecond)

      for _ <- 1..5 do
        Candil.Agents.Crashes.record(name, now)
      end

      assert {:error, :crash_budget_exceeded} =
               AgentsSupervisor.start_agent(SimpleReflex,
                 name: name,
                 goal: "g",
                 backend: EchoBackend
               )
    end

    test "el hijo del supervisor: evaluar, y pararlo" do
      {:ok, pid} =
        AgentsSupervisor.start_agent(SimpleReflex, name: "hijo", goal: "g", backend: EchoBackend)

      assert {:ok, "hola", []} = SimpleReflex.evaluate(pid, "hola")

      assert :ok = AgentsSupervisor.stop_agent(pid)
      assert {:error, :not_found} = AgentsSupervisor.stop_agent(pid)
    end

    test "el child spec: reinicio permanente y cinco segundos de gracia, no brutal_kill" do
      # Las defensas del §8.3 que se leen en el child spec: al parar el árbol
      # hay 5 s de gracia, y el que se cae vuelve.
      spec = SimpleReflex.child_spec([])

      assert spec.restart == :permanent
      assert spec.shutdown == 5_000
      assert spec.type == :worker
    end
  end

  # Como en supervisor_test: el reinicio es del supervisor, no del test.
  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
