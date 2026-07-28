defmodule Candil.Inference.Chat do
  @moduledoc false

  alias Candil.{Config, Engine, Error, HTTP, Model, Provider, RequestBuilder}

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

            HTTP.post_json("#{base_url}/v1/chat/completions", body, [], opts)
            |> parse_openai_response()
          end
      end

    duration = System.monotonic_time() - start

    :telemetry.execute([:candil, :llm, :chat, :stop], %{duration: duration}, %{
      model: model_alias
    })

    result
  end

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
      model: model.name
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

  defp parse_openai_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    choice = get_in(body, ["choices", Access.at(0)])

    {:ok,
     %{
       content: get_in(choice, ["message", "content"]) || "",
       role: get_in(choice, ["message", "role"]) || "assistant",
       model: body["model"] || "",
       finish_reason: choice["finish_reason"],
       tool_calls: parse_openai_tool_calls(get_in(choice, ["message", "tool_calls"])),
       usage: parse_usage(body["usage"])
     }}
  end

  defp parse_openai_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body["error"]["message"] || inspect(body))}
  end

  defp parse_openai_response({:error, reason}), do: {:error, reason}

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

  defp parse_anthropic_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    content =
      body
      |> Map.get("content", [])
      |> Enum.find_value("", fn
        %{"type" => "text", "text" => text} -> text
        _ -> nil
      end)

    {:ok,
     %{
       content: content,
       role: body["role"] || "assistant",
       model: body["model"] || "",
       finish_reason: body["stop_reason"],
       usage: parse_anthropic_usage(body["usage"])
     }}
  end

  defp parse_anthropic_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body["error"]["message"] || inspect(body))}
  end

  defp parse_anthropic_response({:error, reason}), do: {:error, reason}

  defp parse_ollama_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    msg = body["message"] || %{}

    {:ok,
     %{
       content: msg["content"] || "",
       role: msg["role"] || "assistant",
       model: body["model"] || "",
       finish_reason: if(body["done"], do: "stop", else: nil),
       usage: nil
     }}
  end

  defp parse_ollama_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, inspect(body))}
  end

  defp parse_ollama_response({:error, reason}), do: {:error, reason}

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
    case Config.get_model(model_alias) do
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
