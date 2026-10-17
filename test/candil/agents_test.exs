defmodule Candil.AgentsTest do
  @moduledoc """
  La puerta a los agentes (F5.5): encontrarlos por nombre y preguntarles con
  respuesta.

  ## Por qué este test existe

  El RPC entre agentes es la F5.5 (`docs/04-modulos/05-agentes` §5.1): un
  agente se encuentra por su nombre y se le pregunta esperando la respuesta.
  El caso que la fase existe para tapar es el que se ve aquí: un nombre sin
  proceso **contesta** —`{:error, {:agent_not_up, …}, []}`— en vez de salirle
  a quien pregunta un `:noproc` en la cara, y el que se muere mientras esperas
  se despide con una respuesta, no con un exit. Un reventón sí revienta: eso
  lo decidió la F5.3 y aquí se comprueba que sigue siendo verdad.
  """

  use ExUnit.Case, async: false

  alias Candil.Agents
  alias Candil.Agents.{ModelBasedReflex, SimpleReflex, Snapshots}
  alias Candil.Agents.Supervisor, as: AgentsSupervisor
  alias Candil.Tool

  # ── Backends de mentira ─────────────────────────────────────────────────

  defmodule EchoBackend do
    @moduledoc "Hace eco del último mensaje, con el `FINAL_ANSWER` que cierra la vuelta."

    def chat(_model, messages, _opts) do
      content = messages |> List.last() |> Map.fetch!(:content)

      {:ok,
       %{
         content: "FINAL_ANSWER: #{content}",
         finish_reason: "stop",
         usage: %{input_tokens: 0, output_tokens: 0}
       }}
    end
  end

  defmodule SlowBackend do
    @moduledoc "Tarda en contestar: da tiempo a que quien pregunta se canse, o a que al agente lo paren."

    def chat(_model, messages, _opts) do
      Process.sleep(300)
      EchoBackend.chat(nil, messages, [])
    end
  end

  defmodule ExplodingBackend do
    @moduledoc "Revienta: un fallo de programación, y el exit tiene que llegar hasta quien preguntó."

    def chat(_model, _messages, _opts), do: raise("el backend revienta")
  end

  defmodule ScriptedBackend do
    @moduledoc """
    Contesta lo que le pongan en el guion, en orden; sin guion, hace eco.

    El guion vive en `:persistent_term` y no en un `GenServer` a propósito:
    este fichero ya prueba procesos, y lo que se prueba aquí es la puerta, no
    el backend de mentira.
    """

    def push(responses), do: :persistent_term.put({__MODULE__, :responses}, responses)

    def chat(_model, messages, _opts) do
      case :persistent_term.get({__MODULE__, :responses}, []) do
        [next | rest] ->
          :persistent_term.put({__MODULE__, :responses}, rest)
          next

        [] ->
          EchoBackend.chat(nil, messages, [])
      end
    end
  end

  setup do
    # Un nombre único por test: es la identidad, la clave del snapshot y el
    # nombre registrado. Dos tests con el mismo nombre no serían dos tests.
    nombre = "f5-5-#{System.unique_integer([:positive])}"

    Tool.reset()

    on_exit(fn ->
      :persistent_term.erase({ScriptedBackend, :responses})
      Snapshots.forget(nombre)

      # El supervisor de agentes vive en el árbol de la aplicación: aquí no
      # se arranca, se deja limpio (mismo patrón que los tests de los tipos).
      for {_, pid, _, _} <- AgentsSupervisor.list_agents(), is_pid(pid) do
        AgentsSupervisor.stop_agent(pid)
      end
    end)

    %{nombre: nombre}
  end

  describe "la puerta: encontrar por nombre (F5.5)" do
    test "el agente con nombre se encuentra por su nombre", %{nombre: nombre} do
      pid = start_supervised!({SimpleReflex, name: nombre, backend: EchoBackend})

      assert Agents.whereis(nombre) == pid
    end

    test "via/1 es el nombre registrado, con su espacio de nombres" do
      assert Agents.via("router") ==
               {:via, Registry, {Candil.Registry, {:agent, "router"}}}

      assert Agents.whereis("no-existe") == nil
    end

    test "un agente «coder» no pisa al engine «coder»" do
      # El registry es el de la casa, y está compartido: el nombre del agente
      # vive en su espacio (`{:agent, …}`), no en el que usan los alias de
      # modelo. Aquí se ve que los dos caben.
      {:ok, _} = Registry.register(Candil.Registry, "coder", :engine)

      pid = start_supervised!({SimpleReflex, name: "coder", backend: EchoBackend})

      assert Agents.whereis("coder") == pid
      assert [{_, :engine}] = Registry.lookup(Candil.Registry, "coder")
    end

    test "un nombre ya tomado no arranca un segundo agente", %{nombre: nombre} do
      pid = start_supervised!({SimpleReflex, name: nombre, backend: EchoBackend})

      assert {:error, {:already_started, ^pid}} =
               AgentsSupervisor.start_agent(SimpleReflex, name: nombre, backend: EchoBackend)
    end

    test "el tipo 2 también: la puerta es la misma", %{nombre: nombre} do
      start_supervised!({ModelBasedReflex, name: nombre, backend: EchoBackend})

      assert is_pid(Agents.whereis(nombre))
      assert {:ok, "buenas", []} = Agents.call(nombre, "buenas")
    end

    test "la registración sigue al proceso: al caerse y volver, sigue encontrable",
         %{nombre: nombre} do
      pid = start_supervised!({SimpleReflex, name: nombre, backend: ExplodingBackend})

      assert {{%RuntimeError{message: "el backend revienta"}, _}, {GenServer, :call, _}} =
               catch_exit(Agents.call(nombre, "hola"))

      assert wait_until(fn -> Agents.whereis(nombre) not in [nil, pid] end) == :ok
    end
  end

  describe "la pregunta con respuesta (F5.5)" do
    test "por nombre: la respuesta llega", %{nombre: nombre} do
      start_supervised!({SimpleReflex, name: nombre, goal: "eco", backend: EchoBackend})

      assert {:ok, "hola", []} = Agents.call(nombre, "hola")
    end

    test "por pid: también, sin registro de por medio" do
      pid = start_supervised!({SimpleReflex, backend: EchoBackend})

      assert {:ok, "hola", []} = Agents.call(pid, "hola")
    end

    test "un nombre sin proceso contesta; no sale un exit" do
      assert {:error, {:agent_not_up, "fantasma"}, []} = Agents.call("fantasma", "hola")
    end

    test "un pid muerto contesta lo mismo" do
      pid = start_supervised!({SimpleReflex, backend: EchoBackend})

      :ok = GenServer.stop(pid)

      assert {:error, {:agent_not_up, ^pid}, []} = Agents.call(pid, "hola")
    end

    test "el que se muere mientras esperas te lo dice con una respuesta, no con un exit",
         %{nombre: nombre} do
      {:ok, pid} = AgentsSupervisor.start_agent(SimpleReflex, name: nombre, backend: SlowBackend)

      tarea = Task.async(fn -> Agents.call(nombre, "hola") end)
      Process.sleep(50)
      :ok = AgentsSupervisor.stop_agent(pid)

      assert {:error, {:agent_not_up, ^nombre}, []} = Task.await(tarea)
    end

    test "el plazo de quien pregunta es una respuesta, no un exit, y el agente sigue sirviendo",
         %{nombre: nombre} do
      start_supervised!({SimpleReflex, name: nombre, backend: SlowBackend, timeout: 5_000})

      assert {:error, :timeout, []} = Agents.call(nombre, "hola", timeout: 50)

      # La respuesta tardía no deja basura: OTP la descarta (medido), así que
      # pasado el tiempo del run no hay ningún mensaje suelto en el buzón.
      Process.sleep(400)
      refute_received _

      # Y el agente no se murió de que el otro dejara de esperar.
      assert {:ok, "otra", []} = Agents.call(nombre, "otra")
    end

    test "el reventón sí revienta: el exit llega a quien preguntó (F5.3)",
         %{nombre: nombre} do
      start_supervised!({SimpleReflex, name: nombre, backend: ExplodingBackend})

      assert {{%RuntimeError{message: "el backend revienta"}, _}, {GenServer, :call, _}} =
               catch_exit(Agents.call(nombre, "hola"))
    end

    test "un agente pregunta a otro y la respuesta entra en su vuelta", %{nombre: nombre} do
      otro = "a-#{nombre}"

      # La herramienta es de verdad: `Tool.call/2` la busca en el registro
      # global, y lo que hace dentro es la puerta que esta fase construye.
      Tool.define(
        {"preguntar_agente", "Pregunta a otro agente y espera su respuesta",
         %{
           "type" => "object",
           "properties" => %{
             "agente" => %{"type" => "string"},
             "pregunta" => %{"type" => "string"}
           },
           "required" => ["agente", "pregunta"]
         },
         fn %{"agente" => agente, "pregunta" => pregunta} ->
           case Agents.call(agente, pregunta) do
             {:ok, respuesta, _traza} -> {:ok, respuesta}
             {:error, razon, _traza} -> {:error, razon}
           end
         end}
      )

      # El agente que pregunta: primera vuelta, la herramienta; segunda, su
      # respuesta final.
      ScriptedBackend.push([
        {:ok,
         %{
           content:
             ~s(<|tool_call|>\n{"name": "preguntar_agente", "arguments": {"agente": "#{otro}", "pregunta": "¿quién eres?"}}\n<|/tool_call|>),
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }},
        {:ok,
         %{
           content: "FINAL_ANSWER: ya está",
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }}
      ])

      # Los dos agentes de este test no caben bajo el supervisor de ExUnit con
      # el mismo id (el del módulo): el que escucha vive con los demás agentes
      # de la aplicación, que es donde vive un agente de verdad.
      {:ok, _pid_otro} =
        AgentsSupervisor.start_agent(SimpleReflex, name: otro, backend: EchoBackend)

      start_supervised!(
        {SimpleReflex, name: nombre, goal: "preguntar", backend: ScriptedBackend, max_steps: 2}
      )

      assert {:ok, "ya está", traza} = Agents.call(nombre, "empieza")

      # La traza guarda la acción: la respuesta del OTRO agente —la suya, ya
      # extraída del `FINAL_ANSWER`—, tal cual volvió por la puerta.
      assert Enum.any?(
               traza,
               &match?(
                 %{
                   kind: :action,
                   content: %{
                     name: "preguntar_agente",
                     result: {:ok, "¿quién eres?"}
                   }
                 },
                 &1
               )
             )
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        :timeout

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
