defmodule Candil.Agents.ModelBasedReflexTest do
  @moduledoc """
  El tipo 2: una vuelta entera con memoria, y el reinicio que vuelve CON el
  estado.

  ## Por qué este test existe

  La F5.4 (`docs/04-modulos/05-agentes` §5.1, tipo 2) trae `snapshot/1` y
  `restore/1` al behaviour, y el proceso que los usa. El test del reinicio es
  el del §7 —«tras tumbar el agente, vuelve con el estado del último
  snapshot»— con su aviso: *si vuelve vacío, el test pasa si no mira el
  estado*. Así que este test lo mira: `messages`, `rounds` y `last` — y
  además comprueba que la conversación sigue donde estaba.
  """

  use ExUnit.Case, async: false

  alias Candil.Agents.{ModelBasedReflex, Snapshots}
  alias Candil.Agents.Supervisor, as: AgentsSupervisor
  alias Candil.Tool

  # ── Dos backends de mentira, uno por caso ───────────────────────────────

  defmodule QueueBackend do
    @moduledoc """
    Contesta lo que le pongan en la cola, en orden, y avisa al observador de
    qué mensajes vio. Cola vacía = eco (`FINAL_ANSWER: <último mensaje>`).

    Un `{:raise, mensaje}` en la cola revienta: es el reventón del test del
    reinicio, y va por la cola para que el MISMO backend pueda reventar a la
    segunda vuelta y no antes.
    """

    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def push(responses), do: GenServer.call(__MODULE__, {:push, responses})

    def chat(_model, messages, _opts) do
      if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
        send(observer, {:chat_messages, messages})
      end

      case GenServer.call(__MODULE__, :take) do
        nil ->
          content = messages |> List.last() |> Map.fetch!(:content)

          {:ok,
           %{
             content: "FINAL_ANSWER: #{content}",
             finish_reason: "stop",
             usage: %{input_tokens: 0, output_tokens: 0}
           }}

        {:raise, message} ->
          raise message

        response ->
          response
      end
    end

    @impl true
    def init(opts), do: {:ok, %{responses: Keyword.get(opts, :responses, [])}}

    @impl true
    def handle_call(:take, _from, state) do
      case state.responses do
        [] -> {:reply, nil, state}
        [head | tail] -> {:reply, head, %{state | responses: tail}}
      end
    end

    @impl true
    def handle_call({:push, responses}, _from, state) do
      {:reply, :ok, %{state | responses: state.responses ++ responses}}
    end
  end

  defmodule HangingBackend do
    @moduledoc "Se queda dentro para siempre: el backend que se cuelga (§8.3)."

    def chat(_model, _messages, _opts), do: Process.sleep(:infinity)
  end

  setup do
    # Un nombre único por test: es la identidad del agente Y la clave del
    # snapshot. Dos tests con el mismo nombre no serían dos tests — el segundo
    # heredaría el estado del primero, que es justo lo que este tipo hace.
    name = "t2-#{System.unique_integer([:positive])}"

    start_supervised!(QueueBackend)
    Tool.reset()

    :persistent_term.put({QueueBackend, :observer}, self())

    on_exit(fn ->
      :persistent_term.erase({QueueBackend, :observer})
      Snapshots.forget(name)

      # El supervisor de agentes vive en el árbol desde la F5.3: aquí no se
      # arranca, se deja limpio (mismo patrón que el test del tipo 1).
      for {_, pid, _, _} <- AgentsSupervisor.list_agents(), is_pid(pid) do
        AgentsSupervisor.stop_agent(pid)
      end
    end)

    %{name: name}
  end

  describe "el tipo 2: la memoria entre vueltas (F5.4)" do
    test "la segunda vuelta ve la primera: el estado no se va con la llamada", %{name: name} do
      pid =
        start_supervised!(
          {ModelBasedReflex, name: name, goal: "clasificar", backend: QueueBackend}
        )

      assert {:ok, "uno", []} = ModelBasedReflex.evaluate(pid, "uno")

      assert_received {:chat_messages, primera}

      assert primera == [
               %{role: "system", content: "clasificar"},
               %{role: "user", content: "uno"}
             ]

      assert {:ok, "dos", []} = ModelBasedReflex.evaluate(pid, "dos")

      assert_received {:chat_messages, segunda}

      # La segunda vuelta ve la primera ENTERA: es lo que el tipo 1 no hace
      # (allí cada estímulo nace sin memoria).
      assert segunda == [
               %{role: "system", content: "clasificar"},
               %{role: "user", content: "uno"},
               %{role: "user", content: "dos"}
             ]

      # Y el estado lo dice en números.
      status = ModelBasedReflex.status(pid)
      assert status.messages == 2
      assert status.trace == 2
      assert status.rounds == 1
      assert status.last == "dos"
      assert status.restored == false
    end

    test "status/1 cuenta el modelo del mundo antes de trabajar", %{name: name} do
      pid =
        start_supervised!(
          {ModelBasedReflex,
           name: name, goal: "g", backend: QueueBackend, max_steps: 3, timeout: 5_000}
        )

      assert %{
               name: ^name,
               goal: "g",
               backend: QueueBackend,
               model: "default",
               max_steps: 3,
               timeout: 5_000,
               restored: false,
               rounds: 0,
               messages: 0,
               trace: 0,
               last: nil
             } = ModelBasedReflex.status(pid)
    end

    test "una vuelta con herramienta son varios pasos, y el presupuesto se reinicia por vuelta",
         %{name: name} do
      # La herramienta se registra de verdad: `Candil.Tool` vive en el árbol.
      Tool.define({"suma", "Suma", %{}, fn %{"a" => a, "b" => b} -> {:ok, a + b} end})

      guion = [
        {:ok,
         %{
           content:
             ~s(<|tool_call|>\n{"name": "suma", "arguments": {"a": 1, "b": 2}}\n<|/tool_call|>),
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }},
        {:ok,
         %{
           content: "FINAL_ANSWER: 3",
           finish_reason: "stop",
           usage: %{input_tokens: 0, output_tokens: 0}
         }}
      ]

      QueueBackend.push(guion)

      pid =
        start_supervised!(
          {ModelBasedReflex, name: name, goal: "g", backend: QueueBackend, max_steps: 2}
        )

      assert {:ok, "3", traza_vuelta} = ModelBasedReflex.evaluate(pid, "1+2")

      # La traza que se contesta es la de la vuelta: el pensamiento y la
      # acción, sin el paso final.
      assert Enum.any?(traza_vuelta, &match?(%{kind: :action}, &1))
      assert Enum.any?(traza_vuelta, &match?(%{kind: :thought}, &1))

      status = ModelBasedReflex.status(pid)
      assert status.rounds == 2
      assert status.trace == 3
      assert status.messages == 2

      # Y otra vuelta con herramienta vuelve a caber: `rounds` es presupuesto
      # POR vuelta — sin eso, el contador sería un tope de por vida y esta
      # segunda vuelta fallaría con :max_steps_exhausted en el primer paso.
      QueueBackend.push(guion)

      assert {:ok, "3", _} = ModelBasedReflex.evaluate(pid, "otra")

      status = ModelBasedReflex.status(pid)
      assert status.rounds == 2
      assert status.trace == 6
      assert status.messages == 4
    end

    test "sin :backend no arranca, y sin :name tampoco" do
      assert {:error, :no_backend} = ModelBasedReflex.start_link(name: "x", goal: "g")

      assert {:error, :no_name} =
               ModelBasedReflex.start_link(backend: QueueBackend, goal: "g")
    end

    test "un pin que no está en el catálogo es un error al arrancar, y el proceso no nace",
         %{name: name} do
      # Aquí y no en la primera llamada: el estado nace con el proceso, y el
      # modelo tiene que existir antes de que haya estado que fotografiar.
      assert {:error, {:model_not_up, "inventado"}} =
               ModelBasedReflex.start_link(
                 name: name,
                 goal: "g",
                 backend: QueueBackend,
                 model: "inventado"
               )
    end

    test "el hijo del supervisor: evaluar, y pararlo", %{name: name} do
      {:ok, pid} =
        AgentsSupervisor.start_agent(ModelBasedReflex,
          name: name,
          goal: "g",
          backend: QueueBackend
        )

      assert {:ok, "hola", []} = ModelBasedReflex.evaluate(pid, "hola")

      assert :ok = AgentsSupervisor.stop_agent(pid)
      assert {:error, :not_found} = AgentsSupervisor.stop_agent(pid)
    end
  end

  describe "el reinicio de verdad (§7, F5.4)" do
    test "se cae, y vuelve CON su estado", %{name: name} do
      {:ok, pid} =
        AgentsSupervisor.start_agent(ModelBasedReflex,
          name: name,
          goal: "g",
          backend: QueueBackend
        )

      # Una vuelta que termina: deja estado y, con él, el snapshot.
      assert {:ok, "uno", []} = ModelBasedReflex.evaluate(pid, "uno")
      assert_received {:chat_messages, _}

      assert {:ok, snapshot} = Snapshots.load(name)
      assert snapshot.messages == [%{role: "user", content: "uno"}]

      # Y la vuelta que se cae: revienta dentro de su tarea, la tarea va
      # enlazada al agente, y el agente se va con ella.
      QueueBackend.push([{:raise, "el backend revienta"}])

      assert {{%RuntimeError{message: "el backend revienta"}, _}, {GenServer, :call, _}} =
               catch_exit(ModelBasedReflex.evaluate(pid, "dos"))

      # El aviso del backend de la vuelta muerta llegó: el agente sí vio
      # "dos", pero esa vuelta no llegó a terminar.
      assert_received {:chat_messages, muerta}

      assert muerta == [
               %{role: "system", content: "g"},
               %{role: "user", content: "uno"},
               %{role: "user", content: "dos"}
             ]

      # El supervisor lo levanta otra vez — y el nuevo NO nace vacío.
      assert wait_until(fn -> find_new_agent(pid) != nil end)

      nuevo = find_new_agent(pid)
      status = ModelBasedReflex.status(nuevo)

      assert status.restored == true
      # Esto es el §7: si volviera vacío, mirar el estado es lo que lo caza.
      assert status.messages == 1
      assert status.rounds == 1
      assert status.last == "uno"

      # Y no solo el estado: la conversación sigue donde estaba. La vuelta
      # que se murió no dejó rastro — "dos" vivía en la tarea que se fue — y
      # la siguiente ve la última vuelta que TERMINÓ.
      assert {:ok, "ahora", []} = ModelBasedReflex.evaluate(nuevo, "ahora")
      assert_received {:chat_messages, vistos}

      assert vistos == [
               %{role: "system", content: "g"},
               %{role: "user", content: "uno"},
               %{role: "user", content: "ahora"}
             ]
    end

    test "sin ninguna vuelta terminada no hay snapshot: vuelve vacío, pero vuelve", %{name: name} do
      {:ok, pid} =
        AgentsSupervisor.start_agent(ModelBasedReflex,
          name: name,
          goal: "g",
          backend: QueueBackend
        )

      # Se cae en la PRIMERA vuelta: nunca terminó ninguna, así que no hay
      # último estado estable que volver a poner.
      QueueBackend.push([{:raise, "antes de terminar"}])

      assert {{%RuntimeError{message: "antes de terminar"}, _}, {GenServer, :call, _}} =
               catch_exit(ModelBasedReflex.evaluate(pid, "hola"))

      assert wait_until(fn -> find_new_agent(pid) != nil end)

      nuevo = find_new_agent(pid)
      status = ModelBasedReflex.status(nuevo)

      assert status.restored == false
      assert status.messages == 0

      # Y sigue sirviendo: degradado, pero no muerto.
      assert {:ok, "hola", []} = ModelBasedReflex.evaluate(nuevo, "hola")
    end

    test "un snapshot que no se puede restaurar para el arranque: dato roto, no aviso",
         %{name: name} do
      Snapshots.save(name, %{foo: 1})

      assert {:error, {:snapshot_invalid, {:missing_key, :config}}} =
               ModelBasedReflex.start_link(name: name, goal: "g", backend: QueueBackend)
    end
  end

  describe "el cuelgue y el child spec (§8.3)" do
    @tag timeout: 2_000
    test "el backend que no vuelve no cuelga al agente, y el estado se queda donde estaba",
         %{name: name} do
      pid =
        start_supervised!(
          {ModelBasedReflex, name: name, goal: "g", backend: HangingBackend, timeout: 100}
        )

      # El plazo vive dentro, como en el tipo 1: quien llama recibe el error,
      # no un cuelgue.
      assert {:error, :timeout, []} = ModelBasedReflex.evaluate(pid, "hola")

      # El plazo mató la vuelta, no al agente.
      status = ModelBasedReflex.status(pid)
      assert status.messages == 0
      assert status.rounds == 0

      # Y de la vuelta que no terminó no queda snapshot: el «último estado
      # estable» es el de la última vuelta que terminó, y no terminó ninguna.
      assert {:error, :not_found} = Snapshots.load(name)

      assert {:error, :timeout, []} = ModelBasedReflex.evaluate(pid, "otra vez")
    end

    test "el child spec: reinicio permanente y cinco segundos de gracia, no brutal_kill" do
      spec = ModelBasedReflex.child_spec([])

      assert spec.restart == :permanent
      assert spec.shutdown == 5_000
      assert spec.type == :worker
    end
  end

  # Como en supervisor_test: el reinicio es del supervisor, no del test.
  defp find_new_agent(old_pid) do
    AgentsSupervisor.list_agents()
    |> Enum.find_value(fn {_, pid, _, _} -> if is_pid(pid) and pid != old_pid, do: pid end)
  end

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
