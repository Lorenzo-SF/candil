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

  ## Conversation history

  The agent maintains its own conversation; pass an optional
  `Candil.Conversation` to start with a system prompt.

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

  alias Candil.{Cancellation, Conversation, Store, Telemetry, Tool, Tools}

  @type step :: %{kind: :thought | :action | :final, content: term()}
  @type trace :: [step()]
  # `finalize/1` devuelve SIEMPRE tres elementos, tambien en error. El tipo
  # decia dos para el error, y dialyzer no lo veia porque `finalize/1` es
  # privado: la mentira era invisible desde fuera y visible al leer.
  @type result :: {:ok, String.t(), trace()} | {:error, term(), trace()}

  @default_max_steps 8

  @doc """
  Run the agent synchronously. Returns `{:ok, final_answer, trace}` on
  success or `{:error, term()}` on failure.

  ## Options

    * `:backend` — `Candil.Backend` module to use.
    * `:model` — model id (string or atom).
    * `:max_steps` — max loop iterations (default 8).
    * `:cancel_ref` — cancellation ref from `Candil.Cancellation.new_ref/0`.
    * `:conversation` — pre-seeded conversation.
  """
  @spec run(module() | map(), String.t() | nil, keyword()) :: result()
  def run(agent, input, opts \\ [])

  def run(%{} = config, input, opts) do
    do_run(config, input, opts)
  end

  def run(agent_module, input, opts) when is_atom(agent_module) do
    config = agent_module.__agent_config__()
    do_run(config, input, opts)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec do_run(map(), String.t() | nil, keyword()) :: result()
  # El backend se comprueba ANTES que el modelo, y el orden no es cosmetico:
  # `run/3` sin backend y sin modelo devuelve dos errores, y el que se ve es el
  # primero. Sin backend no hay nada que ejecutar, asi que ese es el que se
  # dice; taparlo con «el modelo tampoco existe» esconde el error de codigo
  # detras de uno de configuracion.
  defp do_run(config, input, opts) do
    with {:ok, backend} <- resolve_backend(opts),
         {:ok, model} <- resolve_model(opts, config) do
      run_loop(config, input, opts, backend, model)
    else
      # Siempre TRES elementos, tambien en error, que es lo que dice
      # `@type result` y lo que devuelve `finalize/1`. Un error de dos
      # elementos aqui y de tres al final es la misma trampa dos veces.
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp run_loop(config, input, opts, backend, model) do
    max_steps = Keyword.get(opts, :max_steps, config[:max_steps] || @default_max_steps)
    cancel_ref = Keyword.get(opts, :cancel_ref)

    conversation = Conversation.new(model: model, system: config[:goal])

    conversation =
      if input, do: Conversation.add_message(conversation, "user", input), else: conversation

    trace = loop(conversation, config, backend, model, max_steps, cancel_ref, [])
    finalize(trace)
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

  @spec loop(
          Conversation.t(),
          map(),
          module() | nil,
          String.t() | atom(),
          non_neg_integer(),
          reference() | nil,
          trace()
        ) ::
          trace()
  # `content: :no_backend` y no `content: {:error, :no_backend}`: `finalize/1`
  # ya envuelve en `{:error, content}`, y con el otro se devolvia
  # `{:error, {:error, :no_backend}, trace}` — un error de error.
  defp loop(_conv, _cfg, nil, _model, _steps_left, _ref, trace),
    do: trace ++ [%{kind: :final, content: :no_backend}]

  defp loop(_conv, _cfg, _backend, _model, 0, _ref, trace),
    do: trace ++ [%{kind: :final, content: :max_steps_exhausted}]

  defp loop(conv, cfg, backend, model, steps_left, cancel_ref, trace) do
    if cancel_ref && Cancellation.cancelled?(cancel_ref) do
      Telemetry.emit_cancellation(cancel_ref_to_id(cancel_ref), :cancelled)
      trace ++ [%{kind: :final, content: :cancelled}]
    else
      messages = Conversation.messages(conv)
      prompt_schemas = Tool.list() |> schemas_for(cfg)

      case backend.chat(model, messages, tools: prompt_schemas) do
        {:ok, %{content: content}} ->
          if stop_word_reached?(content, cfg) do
            trace ++ [%{kind: :final, content: extract_final(content, cfg)}]
          else
            continue_or_finish(content, conv, cfg, backend, model, steps_left, cancel_ref, trace)
          end

        {:error, _} = err ->
          trace ++ [%{kind: :final, content: {:error, err}}]
      end
    end
  end

  # Extracted from `loop/7` so the ReAct branch is one level of nesting instead
  # of three. The loop itself reads: cancel? stop-word? otherwise continue.
  @spec continue_or_finish(
          String.t(),
          Conversation.t(),
          map(),
          module(),
          String.t() | atom(),
          integer(),
          reference() | nil,
          trace()
        ) :: trace()
  defp continue_or_finish(content, conv, cfg, backend, model, steps_left, cancel_ref, trace) do
    case Tools.parse_tool_calls(content) do
      {:ok, calls} ->
        trace = trace ++ [%{kind: :thought, content: content}]
        {observations, new_conv} = invoke_tools(calls, conv)

        actions =
          Enum.map(observations, fn {name, result} ->
            %{kind: :action, content: %{name: name, result: result}}
          end)

        loop(new_conv, cfg, backend, model, steps_left - 1, cancel_ref, trace ++ actions)

      {:error, _} ->
        # No tool calls and no stop word — treat the content
        # as the final answer.
        trace ++ [%{kind: :final, content: content}]
    end
  end

  @spec invoke_tools([%{name: String.t(), args: map()}], Conversation.t()) ::
          {[{String.t(), {:ok, term()} | {:error, term()}}], Conversation.t()}
  defp invoke_tools(calls, conv) do
    Enum.reduce(calls, {[], conv}, fn %{name: name, args: args}, {acc, c} ->
      result = Tool.call(name, args)
      # Con `role: "user"`, el modelo recibe su propio resultado como si lo
      # hubiera dicho el usuario: vuelve a pedir la herramienta, y otra vez, y
      # el bucle nunca cierra. Un LLM de verdad espera `role: "tool"`.
      conv = Conversation.add_message(c, "tool", observation_message(name, result))
      {[{name, result} | acc], conv}
    end)
    |> case do
      {acc, conv} -> {Enum.reverse(acc), conv}
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

  @spec finalize(trace()) :: result()
  defp finalize(trace) do
    case List.last(trace) do
      %{kind: :final, content: content} when is_binary(content) ->
        {:ok, content, Enum.reject(trace, &match?(%{kind: :final}, &1))}

      %{kind: :final, content: other} ->
        {:error, other, Enum.reject(trace, &match?(%{kind: :final}, &1))}

      _ ->
        {:ok, "", trace}
    end
  end

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
