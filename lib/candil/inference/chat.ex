defmodule Candil.Inference.Chat do
  @moduledoc false

  alias Candil.{Engine, Error, HTTP, Inference, Model, Provider, RequestBuilder, Store}

  # This module had no `@spec` at all, so dialyzer had to infer the return type
  # from the body — and it inferred one that omitted `{:ok, _}`, which made
  # every caller's success branch look unreachable. `Candil.Context.chat/4`
  # hit it first. The contract is below, written from what the code returns:
  # `parse_openai_response/1` answers `{:ok, response}` for any 2xx.
  @spec do_chat_local(atom(), [Inference.message()], keyword()) ::
          {:ok, Inference.response()} | {:error, term()}
  def do_chat_local(model_alias, messages, opts) do
    start = System.monotonic_time()
    :telemetry.execute([:candil, :llm, :chat, :start], %{}, %{model: model_alias})

    result =
      case Engine.base_url(model_alias) do
        nil ->
          {:error, Error.engine_not_running(model_alias)}

        base_url ->
          with :ok <- validate_context(model_alias, messages, opts) do
            body =
              RequestBuilder.build_openai_body(to_string(model_alias), messages, opts)

            HTTP.post_json(
              "#{base_url}/v1/chat/completions",
              body,
              Engine.auth_headers_for(model_alias),
              opts
            )
            |> parse_openai_response()
          end
      end

    duration = System.monotonic_time() - start

    :telemetry.execute([:candil, :llm, :chat, :stop], %{duration: duration}, %{
      model: model_alias,
      finish_reason: finish_reason(result),
      prompt_hash: prompt_hash(messages)
    })

    result
  end

  @spec do_chat_remote(Model.t(), Provider.t(), [Inference.message()], keyword()) ::
          {:ok, Inference.response()} | {:error, term()}
  def do_chat_remote(%Model{} = model, %Provider{} = provider, messages, opts) do
    start = System.monotonic_time()
    :telemetry.execute([:candil, :llm, :chat, :start], %{}, %{model: model.name})

    result =
      with :ok <- validate_context(model, messages, opts) do
        body = build_request_body(provider.type, model.name, messages, opts)
        headers = Provider.auth_headers(provider)
        parser = response_parser(provider.type)

        HTTP.post_json(Provider.chat_url(provider), body, headers, opts)
        |> parser.()
      end

    duration = System.monotonic_time() - start

    :telemetry.execute([:candil, :llm, :chat, :stop], %{duration: duration}, %{
      model: model.name,
      finish_reason: finish_reason(result),
      prompt_hash: prompt_hash(messages)
    })

    result
  end

  defp build_request_body(:anthropic, model, messages, opts),
    do: RequestBuilder.build_anthropic_body(model, messages, opts)

  defp build_request_body(:ollama, model, messages, opts),
    do: RequestBuilder.build_ollama_chat_body(model, messages, opts)

  defp build_request_body(:openai, model, messages, opts),
    do: RequestBuilder.build_openai_body(model, messages, opts)

  defp build_request_body(:openai_compatible, model, messages, opts),
    do: RequestBuilder.build_openai_body(model, messages, opts)

  defp build_request_body(:azure_openai, model, messages, opts),
    do: RequestBuilder.build_openai_body(model, messages, opts)

  defp response_parser(:anthropic), do: &parse_anthropic_response/1
  defp response_parser(:ollama), do: &parse_ollama_response/1
  defp response_parser(:openai), do: &parse_openai_response/1
  defp response_parser(:openai_compatible), do: &parse_openai_response/1
  defp response_parser(:azure_openai), do: &parse_openai_response/1

  @doc false
  def parse_openai_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    choice = get_in(body, ["choices", Access.at(0)])

    {:ok,
     %{
       content: get_in(choice, ["message", "content"]) || "",
       # El razonamiento **no se pierde y no se inventa**: si el servidor lo
       # manda en `reasoning_content`, aqui esta; si no lo manda, `nil`.
       #
       # Medido el 2026-10-14 con `Qwen3.8-27B` y `--reasoning-format
       # deepseek`, que es como lo tiene el catalogo: 1996 bytes de
       # razonamiento —con la duda de si contaba al granjero— y `content` con
       # la respuesta final. Antes ese razonamiento se caia al suelo sin dejar
       # rastro, y `finish_reason` es `"stop"` en las dos casos: un cliente no
       # tenia forma de saber que habia habido razonamiento.
       #
       # Y no todos los modelos razonan: con `Qwen3-Coder-30B` y el mismo flag
       # la respuesta **no trae** `reasoning_content`. Por eso `nil` es una
       # respuesta valida y no un fallo.
       reasoning: get_in(choice, ["message", "reasoning_content"]),
       role: get_in(choice, ["message", "role"]) || "assistant",
       model: body["model"] || "",
       finish_reason: choice["finish_reason"],
       tool_calls: parse_openai_tool_calls(get_in(choice, ["message", "tool_calls"])),
       usage: parse_usage(body["usage"])
     }}
  end

  @doc false
  def parse_openai_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body["error"]["message"] || inspect(body))}
  end

  @doc false
  def parse_openai_response({:error, reason}), do: {:error, reason}

  # Lo que el evento de telemetria necesita para que la calidad sea medible sin
  # que quien lo lee tenga que mirar dentro de la respuesta.
  #
  # `finish_reason` es lo que separa **un modelo roto** de **una respuesta mala**:
  # `length` quiere decir que se quedo sin tokens, `content_filter` que se
  # negaron. Sin esto, la unica senal de calidad seria el reintento, que es
  # retrasado y necesita cientos de muestras.
  defp finish_reason({:ok, %{finish_reason: reason}}), do: reason
  defp finish_reason(_otro), do: nil

  # El hash del ultimo turno de usuario. Es lo que permite reconocer que una
  # peticion es **la misma pregunta repetida**, que es la unica forma de ver
  # un reintento sin un boton de feedback.
  #
  # Sin `consumer`: la llamada no lo sabe, y dos consumers con el mismo prompt
  # se podrian atribuir el reintento el uno al otro. Se dice en el modulo que
  # cuenta, no se esconde.
  defp prompt_hash(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} -> content
      _otro -> nil
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp parse_openai_tool_calls(nil), do: nil
  defp parse_openai_tool_calls([]), do: nil

  defp parse_openai_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn c ->
      args_json = get_in(c, ["function", "arguments"]) || "{}"

      %{
        id: c["id"],
        name: get_in(c, ["function", "name"]),
        arguments:
          try do
            Jason.decode!(args_json)
          rescue
            Jason.DecodeError -> %{}
          end
      }
    end)
  end

  @doc false
  def parse_anthropic_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    bloques = Map.get(body, "content", [])

    # Anthropic manda el razonamiento en bloques `{"type": "thinking",
    # "thinking": "..."}` y el texto en `{"type": "text"}`. Antes solo se leia
    # el texto y cualquier otro bloque se descartaba **sin mirar que era**.
    #
    # Se **concatenan todos** los bloques de razonamiento: Claude trocea el
    # pensamiento en varios, y quedarse con el primero es tan falso como
    # quedarse con ninguno.
    texto =
      Enum.find_value(bloques, "", fn
        %{"type" => "text", "text" => texto} -> texto
        _ -> nil
      end)

    razonamiento =
      bloques
      |> Enum.flat_map(fn
        %{"type" => "thinking", "thinking" => pensando} when is_binary(pensando) -> [pensando]
        _ -> []
      end)
      |> case do
        [] -> nil
        partes -> Enum.join(partes, "\n")
      end

    {:ok,
     %{
       content: texto,
       reasoning: razonamiento,
       role: body["role"] || "assistant",
       model: body["model"] || "",
       finish_reason: body["stop_reason"],
       usage: parse_anthropic_usage(body["usage"])
     }}
  end

  @doc false
  def parse_anthropic_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body["error"]["message"] || inspect(body))}
  end

  @doc false
  def parse_anthropic_response({:error, reason}), do: {:error, reason}

  @doc false
  def parse_ollama_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    msg = body["message"] || %{}

    {:ok,
     %{
       content: msg["content"] || "",
       # Ollama separa el razonamiento en `message.thinking` y la respuesta en
       # `message.content` —documentacion de Ollama, "Thinking"—. Y vacio es
       # `nil`, no una cadena: un modelo que no razona no tiene un
       # razonamiento vacio, no tiene razonamiento.
       reasoning:
         case msg["thinking"] do
           vacio when vacio in [nil, ""] -> nil
           pensando -> pensando
         end,
       role: msg["role"] || "assistant",
       model: body["model"] || "",
       finish_reason: if(body["done"], do: "stop", else: nil),
       usage: nil
     }}
  end

  @doc false
  def parse_ollama_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, inspect(body))}
  end

  @doc false
  def parse_ollama_response({:error, reason}), do: {:error, reason}

  defp parse_usage(nil), do: nil

  defp parse_usage(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
  end

  defp parse_anthropic_usage(nil), do: nil

  defp parse_anthropic_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: input + output
    }
  end

  defp validate_context(model_alias, messages, opts) when is_atom(model_alias) do
    case Store.get_model(model_alias) do
      {:ok, model} -> validate_context(model, messages, opts)
      {:error, _} -> :ok
    end
  end

  defp validate_context(%Model{context_size: ctx}, messages, _opts)
       when is_integer(ctx) and ctx > 0 do
    estimated = estimate_tokens(messages)

    if estimated > ctx do
      {:error, Error.context_overflow(estimated, ctx)}
    else
      :ok
    end
  end

  defp validate_context(_, _, _), do: :ok

  defp estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.reduce(0, fn msg, acc ->
      tokens = (msg[:content] || msg["content"] || "") |> String.length() |> div(4)
      acc + tokens
    end)
    |> Kernel.+(length(messages) * 4)
  end

  defp estimate_tokens(_), do: 0
end
