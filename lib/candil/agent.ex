defmodule Candil.Agent do
  @moduledoc """
  A minimal ReAct-style agent that uses tools.

  ReAct (Reason + Act) alternates between:
    1. Reasoning — the model decides what to do next.
    2. Acting — invoke a tool if needed.
    3. Observing — feed the tool's result back as a new message.

  The loop continues until either:
    * The model emits a final answer (no tool calls).
    * `max_steps` is reached (default 8).

  ## The behaviour, and the loop

  Since F5.2 this module implements `Candil.Agents.Behaviour`: `init_agent/1`
  builds the state and `step/3` is one ReAct round — a function, not a
  message, so a step can be exercised without starting a process. `run/3` is
  the synchronous driver: init, steps until `:final`, result. The recursion
  `loop/7` used to have is a `reduce_while` inside it.

  ## The history

  The history lives in the state. Name a `:session` and it lives in
  `Candil.Context` instead: the run starts from what the session holds and
  leaves its turn there, so the next run continues the conversation. Without a
  session, the history belongs to the call and goes with it.

  `Candil.Conversation`, which kept the history in the process that called it,
  is deprecated and goes in 4.1.0; this module was its last consumer inside
  the house, and it migrated in F5.2.

  ## The last state worth restarting from

  The two optional callbacks of the behaviour arrived with F5.4: `snapshot/1`
  turns the state into plain data — a cancellation reference belongs to the
  run that asked for it and is left out — and `restore/1` builds the state
  back, or says why the map was not one. `finalize/1` is public for the same
  reason: the process that drives `step/3` and keeps the state
  (`Candil.Agents.ModelBasedReflex`) answers with the same result shape
  `run/3` does, from one mapping.

  ## Stop words

  If the model's response contains one of the configured stop words
  (default `"FINAL_ANSWER"`), the loop terminates.

  ## Example

      defmodule MyApp.WeatherAgent do
        use Candil.Agent,
          name: "weather",
          goal: "Answer weather questions",
          tools: [Candil.MyTools.get_weather],
          max_steps: 6
      end

      MyApp.WeatherAgent.run("What's the weather in Madrid?")
  """

  @behaviour Candil.Agents.Behaviour

  alias Candil.{
    Cancellation,
    Context,
    Inference,
    Store,
    Telemetry,
    Tool,
    Tools
  }

  alias Candil.Context.Session

  @type step :: %{kind: :thought | :action | :final, content: term()}
  @type trace :: [step()]
  # `finalize/1` devuelve SIEMPRE tres elementos, tambien en error. El tipo
  # decia dos para el error, y dialyzer no lo veia porque `finalize/1` es
  # privado: la mentira era invisible desde fuera y visible al leer.
  @type result :: {:ok, String.t(), trace()} | {:error, term(), trace()}

  @typedoc """
  What a `step/3` tells the driver: keep going (`:thought`) or stop (`:final`).
  """
  @type outcome :: %{kind: :thought | :final, content: term()}

  @typedoc """
  The state a step threads through: the ReAct history and what it costs to
  take one more turn.
  """
  @type agent_state :: %{
          config: map(),
          backend: module(),
          model: String.t() | atom(),
          max_steps: non_neg_integer(),
          rounds: non_neg_integer(),
          cancel_ref: reference() | nil,
          consumer: atom(),
          session: String.t() | nil,
          messages: [Inference.message()],
          trace: trace()
        }

  @default_max_steps 8
  @default_consumer :candil_agent

  # Las claves que tiene la forma del estado, sin `cancel_ref`: `snapshot/1`
  # la quita —una referencia no sobrevive con sentido— y `restore/1` la
  # devuelve como `nil`. El orden solo manda en el mensaje de error: se
  # nombra la primera que falte.
  @snapshot_keys [
    :config,
    :backend,
    :model,
    :max_steps,
    :rounds,
    :consumer,
    :session,
    :messages,
    :trace
  ]

  defstruct [:pid, :name]

  @doc """
  Creates a high-level agent that hides the backend/model/engine ceremony.

  ## Options

    * `:model` — model alias (string or atom). Default: `"default"`.
    * `:goal` — the agent's goal (goes in the system prompt).
    * `:tools` — list of tool names to register (atoms or strings).
    * `:max_steps` — max ReAct steps (default: 8).
    * `:timeout` — per-run timeout in ms (default: 60_000).
    * `:name` — optional name for registry.
    * `:backend` — backend module (default: `Candil.Backend.LlamaCpp`).

  ## Example

      agent = Candil.Agent.new(model: "vision", goal: "clasificar", max_steps: 3)
      {:ok, answer, trace} = Candil.Agent.run(agent, "hola")
  """
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, "default")
    goal = Keyword.get(opts, :goal)
    tools = Keyword.get(opts, :tools, [])
    max_steps = Keyword.get(opts, :max_steps, 8)
    timeout = Keyword.get(opts, :timeout, 60_000)
    name = Keyword.get(opts, :name)
    backend = Keyword.get(opts, :backend, Candil.Backend.LlamaCpp)

    Enum.each(tools, fn tool ->
      if is_atom(tool) do
        # Tool names as atoms are already registered modules; nothing to do.
        :ok
      else
        :ok
      end
    end)

    alias_ = Candil.resolve_model_alias(model)

    if alias_ != nil do
      Candil.ensure_engine_running(alias_, opts)
    end

    {:ok, pid} =
      Candil.Agents.Supervisor.start_agent(Candil.Agents.SimpleReflex,
        name: name,
        goal: goal,
        backend: backend,
        model: model,
        max_steps: max_steps,
        timeout: timeout
      )

    %__MODULE__{pid: pid, name: name}
  end

  @doc """
  Run the agent synchronously. Returns `{:ok, final_answer, trace}` on
  success or `{:error, reason, trace}` on failure — always three elements,
  also in error.

  ## Options

    * `:backend` — `Candil.Backend` module to use.
    * `:model` — model id (string or atom).
    * `:max_steps` — max loop iterations (default 8).
    * `:cancel_ref` — cancellation ref from `Candil.Cancellation.new_ref/0`.
    * `:session` — a `Candil.Context` session id. With one, the history is
      read from that session and left in it, so the next run with the same id
      continues where this one stopped; without one, the history is this
      call's.
    * `:consumer` — the partition the `:session` lives in (default
      `:candil_agent`).
  """
  @spec run(module() | map() | %__MODULE__{}, String.t() | nil, keyword()) :: result()
  def run(agent, input, opts \\ [])

  def run(%__MODULE__{pid: pid}, input, opts) do
    Candil.Agents.call(pid, input, opts)
  end

  def run(%{} = config, input, opts) do
    do_run(config, input, opts)
  end

  def run(agent_module, input, opts) when is_atom(agent_module) do
    config = agent_module.__agent_config__()
    do_run(config, input, opts)
  end

  @impl true
  @doc """
  Builds the initial state: backend, model, budget, and the history — read
  from the `:session` when one is named, empty when it is not.

  The two ways a run can die before it starts — no backend, a model alias
  that is not in the catalogue — die here, with their own reason.
  """
  @spec init_agent(keyword()) :: {:ok, agent_state()} | {:stop, term()}
  def init_agent(opts) do
    config = Keyword.get(opts, :config, %{})

    with {:ok, backend} <- resolve_backend(opts),
         {:ok, model} <- resolve_model(opts, config) do
      consumer = Keyword.get(opts, :consumer, @default_consumer)
      session = Keyword.get(opts, :session)

      {:ok,
       %{
         config: config,
         backend: backend,
         model: model,
         max_steps: Keyword.get(opts, :max_steps, config[:max_steps] || @default_max_steps),
         rounds: 0,
         cancel_ref: Keyword.get(opts, :cancel_ref),
         consumer: consumer,
         session: session,
         messages: session_messages(consumer, session),
         trace: []
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  @doc """
  One ReAct round: record the input, one call to the backend, and the tool
  calls it asks for — or the end.

  Returns the state and what the round was: `:thought` to keep going,
  `:final` to stop. A round always completes, so the failures that end a run
  (`:max_steps_exhausted`, `:cancelled`, a backend error) travel in the
  trace, which is where `finalize/1` turns them into `result()`.
  """
  @spec step(agent_state(), term(), keyword()) :: {:ok, agent_state(), outcome()}
  def step(state, input, _opts \\ []) do
    state = record_input(state, input)

    cond do
      state.rounds >= state.max_steps ->
        finish(state, :max_steps_exhausted)

      cancelled?(state) ->
        Telemetry.emit_cancellation(cancel_ref_to_id(state.cancel_ref), :cancelled)
        finish(state, :cancelled)

      true ->
        react_round(state)
    end
  end

  @impl true
  @doc """
  The last state worth restarting from: the whole state as plain data.

  Plain means serializable — modules, strings, numbers, maps and lists.
  `cancel_ref` is left out on purpose: a reference belongs to the run that
  asked for it, and a run that died is not cancelled by a restart.
  `restore/1` brings it back as `nil`.
  """
  @spec snapshot(agent_state()) :: map()
  def snapshot(state) when is_map(state) do
    Map.delete(state, :cancel_ref)
  end

  @impl true
  @doc """
  Builds the state back from a snapshot, or refuses it.

  A map missing any of the fields the state is made of is not a snapshot: the
  reason names the missing key, because a restore that half-works is a state
  that fails later and somewhere else. `Map.take/2` and not `Map.put/3`: what
  goes back in is exactly the state's shape, so a field someone else added
  does not travel as if it were part of the agent.
  """
  @spec restore(map()) :: {:ok, agent_state()} | {:error, term()}
  def restore(snapshot) when is_map(snapshot) do
    case Enum.find(@snapshot_keys, &(not Map.has_key?(snapshot, &1))) do
      nil ->
        {:ok, snapshot |> Map.take(@snapshot_keys) |> Map.put(:cancel_ref, nil)}

      missing ->
        {:error, {:missing_key, missing}}
    end
  end

  def restore(_other), do: {:error, :not_a_snapshot}

  @doc """
  The result a trace ends in — what `run/3` answers.

  Public since F5.4: the process that drives `step/3` answers with the same
  shape, and the mapping from trace to result lives here and not in two
  places.
  """
  @spec finalize(trace()) :: result()
  def finalize(trace) do
    case List.last(trace) do
      %{kind: :final, content: content} when is_binary(content) ->
        {:ok, content, Enum.reject(trace, &match?(%{kind: :final}, &1))}

      %{kind: :final, content: other} ->
        {:error, other, Enum.reject(trace, &match?(%{kind: :final}, &1))}

      _ ->
        {:ok, "", trace}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec do_run(map(), String.t() | nil, keyword()) :: result()
  defp do_run(config, input, opts) do
    case init_agent(Keyword.put(opts, :config, config)) do
      {:ok, state} ->
        state = drive(state, input)
        persist(state)
        finalize(state.trace)

      {:stop, reason} ->
        # Siempre TRES elementos, tambien en error, que es lo que dice
        # `@type result` y lo que devuelve `finalize/1`. Un error de dos
        # elementos aqui y de tres al final es la misma trampa dos veces.
        {:error, reason, []}
    end
  end

  # El bucle de ReAct ya no es recursion: es un reductor. Cada vuelta es
  # `step/3`, y quien decide parar es el paso (`:final`). No hay tope aqui
  # porque el tope vive en el estado: `rounds` contra `max_steps`.
  @spec drive(agent_state(), String.t() | nil) :: agent_state()
  defp drive(state, input) do
    {final_state, _input} =
      Enum.reduce_while(Stream.iterate(0, &(&1 + 1)), {state, input}, fn _, {st, inp} ->
        {:ok, st, outcome} = step(st, inp, [])

        if outcome.kind == :final,
          do: {:halt, {st, nil}},
          else: {:cont, {st, nil}}
      end)

    final_state
  end

  @spec react_round(agent_state()) :: {:ok, agent_state(), outcome()}
  defp react_round(state) do
    messages = prompt(state)
    prompt_schemas = Tool.list() |> schemas_for(state.config)
    state = %{state | rounds: state.rounds + 1}

    case state.backend.chat(state.model, messages, tools: prompt_schemas) do
      {:ok, %{content: content}} ->
        if stop_word_reached?(content, state.config) do
          finish(state, extract_final(content, state.config))
        else
          continue_or_finish(content, state)
        end

      {:error, _} = err ->
        finish(state, {:error, err})
    end
  end

  # Extracted from `loop/7` so the ReAct branch stays one level of nesting
  # deep. A round reads: tool calls? act and keep going. Otherwise, final.
  @spec continue_or_finish(String.t(), agent_state()) :: {:ok, agent_state(), outcome()}
  defp continue_or_finish(content, state) do
    case Tools.parse_tool_calls(content) do
      {:ok, calls} ->
        trace = state.trace ++ [%{kind: :thought, content: content}]
        {observations, messages} = invoke_tools(calls, state.messages)

        actions =
          Enum.map(observations, fn {name, result} ->
            %{kind: :action, content: %{name: name, result: result}}
          end)

        {:ok, %{state | messages: messages, trace: trace ++ actions},
         %{kind: :thought, content: content}}

      {:error, _} ->
        # No tool calls and no stop word — treat the content
        # as the final answer.
        finish(state, content)
    end
  end

  @spec finish(agent_state(), term()) :: {:ok, agent_state(), outcome()}
  defp finish(state, content) do
    trace = state.trace ++ [%{kind: :final, content: content}]
    {:ok, %{state | trace: trace}, %{kind: :final, content: content}}
  end

  @spec record_input(agent_state(), String.t() | nil) :: agent_state()
  defp record_input(state, nil), do: state

  defp record_input(state, input) when is_binary(input) do
    %{state | messages: state.messages ++ [%{role: "user", content: input}]}
  end

  # El prompt del sistema va fuera de la historia, como lo tenia
  # `Conversation.messages/1`: la sesion guarda el intercambio, no el
  # personaje. Un `goal` nil no anade mensaje; uno vacio si, que es lo que
  # hacia antes — se conserva a proposito.
  @spec prompt(agent_state()) :: [Inference.message()]
  defp prompt(%{config: config, messages: messages}) do
    case config[:goal] do
      nil -> messages
      goal -> [%{role: "system", content: goal} | messages]
    end
  end

  @spec cancelled?(agent_state()) :: boolean()
  defp cancelled?(%{cancel_ref: nil}), do: false
  defp cancelled?(%{cancel_ref: ref}), do: Cancellation.cancelled?(ref)

  # Los mensajes COMPLETOS, no `live_messages/1`: este bucle no resume, y al
  # devolver la sesion se reescribe entera — quedarse con los vivos tiraria
  # lo resumido.
  @spec session_messages(atom(), String.t() | nil) :: [Inference.message()]
  defp session_messages(_consumer, nil), do: []

  defp session_messages(consumer, session) do
    case Context.get(consumer, session) do
      {:ok, %Session{messages: messages}} -> messages
      {:error, :not_found} -> []
    end
  end

  # La historia del run queda en la sesion (F5.2): la siguiente llamada con
  # el mismo `:session` continua la conversacion. Sin sesion no hay donde
  # dejarla — y no se deja.
  @spec persist(agent_state()) :: :ok
  defp persist(%{session: nil}), do: :ok
  defp persist(%{messages: []}), do: :ok

  defp persist(%{consumer: consumer, session: session, messages: messages}) do
    {:ok, _} = Context.create(consumer, session)

    Context.update(consumer, session, fn s ->
      Session.touch(%{s | messages: messages})
    end)
  end

  # Sin backend, `nil`: un modulo. Antes era `nil | module()` y quien llamaba
  # acababa en `nil.chat/3`, que es un `UndefinedFunctionError` sin nombre de
  # agente, sin modelo y sin `@spec` que lo anunciara.
  @spec resolve_backend(keyword()) :: {:ok, module()} | {:error, :no_backend}
  defp resolve_backend(opts) do
    case opts[:backend] do
      nil -> {:error, :no_backend}
      mod -> {:ok, mod}
    end
  end

  # Antes devolvia el alias **tal cual**, sin comprobar nada: un modelo
  # inventado llegaba entero al backend y el error —si lo habia— era del motor,
  # no de aqui. Un pin que no existe es un error ruidoso, y el punto de
  # encontrarlo es aqui.
  # El motivo va anidado, `{:error, {:model_not_up, alias}}`, y no plano. La
  # tercera posicion de `result()` es la TRAZA, y un alias ahi no es una traza:
  # el guion decia `{:error, :model_not_up, "inventado"}` y el tipo no lo hacia
  # falso, pero obliga a que quien lo lea adivine cual de los dos ultimos es la
  # traza.
  @spec resolve_model(keyword(), map()) ::
          {:ok, String.t() | atom()} | {:error, {atom(), String.t() | atom()}}
  defp resolve_model(opts, config) do
    requested = Keyword.get(opts, :model) || config[:model] || "default"

    if model_known?(requested),
      do: {:ok, requested},
      else: {:error, {:model_not_up, requested}}
  end

  # Por la lista y no por `Store.get_model/1`, que exige un atomo y aqui el
  # modelo llega como string. Comparar sobre `to_string/1` evita
  # `String.to_existing_atom/1`, que crea un atomo con una cadena que viene de
  # fuera: un pin inventado no debe dejar atomos en la maquina.
  defp model_known?(requested) do
    # "default" NO es un alias del catalogo: es un centinela que dice «elige
    # tu». Un backend HTTP contra un llama-server lo ignora, y un backend de
    # pruebas lo necesita. Comprobarlo contra el Store lo convertiria en un
    # modelo imposible.
    to_string(requested) == "default" or
      Enum.any?(Store.list_models(), &(to_string(&1.alias) == to_string(requested)))
  end

  @spec invoke_tools([%{name: String.t(), args: map()}], [Inference.message()]) ::
          {[{String.t(), {:ok, term()} | {:error, term()}}], [Inference.message()]}
  defp invoke_tools(calls, messages) do
    Enum.reduce(calls, {[], messages}, fn %{name: name, args: args}, {acc, msgs} ->
      result = Tool.call(name, args)
      # Con `role: "user"`, el modelo recibe su propio resultado como si lo
      # hubiera dicho el usuario: vuelve a pedir la herramienta, y otra vez, y
      # el bucle nunca cierra. Un LLM de verdad espera `role: "tool"`.
      msgs = msgs ++ [%{role: "tool", content: observation_message(name, result)}]
      {[{name, result} | acc], msgs}
    end)
    |> case do
      {acc, msgs} -> {Enum.reverse(acc), msgs}
    end
  end

  @spec observation_message(String.t(), {:ok, term()} | {:error, term()}) :: String.t()
  defp observation_message(name, result) do
    "Observation (#{name}): #{inspect(result)}"
  end

  @spec schemas_for([Tool.t()], map()) :: [map()]
  defp schemas_for(tools_in_registry, cfg) do
    cfg_schemas = cfg[:tool_schemas] || []
    reg_schemas = Tools.schemas_to_prompt(tools_in_registry)
    cfg_schemas ++ reg_schemas
  end

  @spec stop_word_reached?(String.t(), map()) :: boolean()
  defp stop_word_reached?(content, cfg) do
    stop = cfg[:stop_word] || "FINAL_ANSWER"
    String.contains?(content, stop)
  end

  @spec extract_final(String.t(), map()) :: String.t()
  defp extract_final(content, cfg) do
    stop = cfg[:stop_word] || "FINAL_ANSWER"

    # Take the text AFTER the stop word (ReAct convention:
    # "FINAL_ANSWER: <answer>"), fall back to the whole content.
    case String.split(content, stop) do
      [_] -> String.trim(content)
      [_prefix, rest | _] -> rest |> String.trim() |> String.trim_leading(":") |> String.trim()
    end
  end

  @spec cancel_ref_to_id(reference()) :: String.t()
  defp cancel_ref_to_id(ref), do: inspect(ref)

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    goal = Keyword.get(opts, :goal, "")
    tools = Keyword.get(opts, :tools, [])
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    tool_schemas = Tools.schemas_to_prompt(tools)

    quote do
      def __agent_config__ do
        %{
          name: unquote(name),
          goal: unquote(goal),
          max_steps: unquote(max_steps),
          tool_schemas: unquote(Macro.escape(tool_schemas))
        }
      end

      def run(input, opts \\ []) do
        Candil.Agent.run(__MODULE__, input, opts)
      end
    end
  end
end
