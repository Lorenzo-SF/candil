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

    test "status/1 cuenta la configuración, y no cambia entre llamadas" do
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
        timeout: 60_000
      }

      assert SimpleReflex.status(pid) == esperado

      assert {:ok, "uno", []} = SimpleReflex.evaluate(pid, "uno")

      # Después de trabajar, exactamente lo mismo: no acumula nada.
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
      pid =
        start_supervised!(
          {SimpleReflex, name: "colgado", goal: "g", backend: HangingBackend, timeout: 100}
        )

      # El plazo vive dentro: quien llama recibe el error, no un cuelgue. El
      # plazo es corto a propósito; si el agente se colgara de verdad, el
      # `@tag timeout:` de arriba corta el test en 2 s en vez de agotar el
      # timeout global (60 s).
      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "hola")

      # El plazo mató la llamada, no al agente: sigue vivo y sirviendo.
      assert %{name: "colgado"} = SimpleReflex.status(pid)
      assert {:error, :timeout, []} = SimpleReflex.evaluate(pid, "otra vez")
    end

    test "un run que revienta se lleva al agente, y el supervisor lo levanta" do
      {:ok, pid} =
        AgentsSupervisor.start_agent(SimpleReflex,
          name: "terco",
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
