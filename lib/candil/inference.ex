defmodule Candil.Inference do
  @moduledoc """
  Inference execution for Candil.

  Handles chat completions and embeddings for both local engines and remote
  providers. Normalises the request/response format across the supported
  provider APIs (OpenAI, Anthropic, Ollama, OpenAI-compatible).

  ## Message format

  All messages are plain maps with `:role` and `:content` string keys:

      %{role: "system", content: "You are a helpful assistant."}
      %{role: "user", content: "Hello!"}
      %{role: "assistant", content: "Hi there!"}

  ## Response format

  All chat functions return a `response()` map:

      %{
        content: "Hello, how can I help?",
        role: "assistant",
        model: "llama-3-8b",
        finish_reason: "stop",
        usage: %{prompt_tokens: 12, completion_tokens: 8, total_tokens: 20}
      }

  """

  alias Candil.{Config, Engine, Error, HTTP, Model, Provider, RequestBuilder}

  @type message :: %{required(:role) => binary(), required(:content) => binary()}

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type response :: %{
          content: binary(),
          role: binary(),
          model: binary(),
          finish_reason: binary() | nil,
          usage: usage() | nil
        }

  @type embed_response :: [[float()]]

  @doc """
  Runs a chat completion against a local llama-server.

  The engine must be running and healthy. Resolves the server URL from the
  registry via the model alias.

  ## Options

    * `:temperature` — sampling temperature 0.0–2.0 (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences (default: `[]`)
    * `:system` — system prompt string (prepended to messages if set)

  """
  @spec chat_local(atom(), [message()], keyword()) :: {:ok, response()} | {:error, Error.t()}
  def chat_local(model_alias, messages, opts \\ []) do
    with {:ok, model} <- Config.get_model(model_alias),
         true <-
           :chat in model.usage || :completion in model.usage ||
             (model.type == :remote && :chat in model.usage) do
      do_chat_local(model_alias, messages, opts)
    else
      {:error, :not_found} ->
        {:error, Error.model_not_found(model_alias)}

      false ->
        {:error, Error.invalid_request("Model #{model_alias} does not support chat")}
    end
  end

  defp do_chat_local(model_alias, messages, opts) do
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

  @doc """
  Runs a chat completion against a remote provider.

  Dispatches to the appropriate provider module based on `provider.type`.

  ## Options

  Same as `chat_local/3`.
  """
  @spec chat_remote(Model.t(), Provider.t(), [message()], keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def chat_remote(%Model{} = model, %Provider{} = provider, messages, opts) do
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

  # Provider-type dispatch — single source of truth.
  # Adding a new provider is a 2-line change: a body builder and a parser
  # (or reuse one of the existing ones).

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

  @doc """
  Generates embeddings for a list of texts against a local engine.

  The model must have `:embeddings` in its `usage` list.
  """
  @spec embed_local(atom(), [binary()], keyword()) ::
          {:ok, embed_response()} | {:error, Error.t()}
  def embed_local(model_alias, texts, _opts \\ []) do
    with {:ok, model} <- Config.get_model(model_alias),
         true <- :embeddings in model.usage do
      do_embed_local(model_alias, texts)
    else
      {:error, :not_found} ->
        {:error, Error.model_not_found(model_alias)}

      false ->
        {:error, Error.invalid_request("Model #{model_alias} does not support embeddings")}
    end
  end

  defp do_embed_local(model_alias, texts) do
    case Engine.base_url(model_alias) do
      nil ->
        {:error, Error.engine_not_running(model_alias)}

      base_url ->
        body = %{input: texts}

        HTTP.post_json("#{base_url}/v1/embeddings", body, [], [])
        |> parse_embeddings_response()
    end
  end

  @doc """
  Generates embeddings for a list of texts against a remote provider.
  """
  @spec embed_remote(Model.t(), Provider.t(), [binary()], keyword()) ::
          {:ok, embed_response()} | {:error, Error.t()}
  def embed_remote(%Model{} = model, %Provider{type: :ollama} = provider, texts, _opts) do
    headers = Provider.auth_headers(provider)

    results =
      Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
        body = %{model: model.name, prompt: text}

        case HTTP.post_json(Provider.embeddings_url(provider), body, headers, [])
             |> parse_ollama_embedding() do
          {:ok, embedding} -> {:cont, {:ok, [embedding | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case results do
      {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
      err -> err
    end
  end

  def embed_remote(%Model{} = model, %Provider{} = provider, texts, _opts) do
    headers = Provider.auth_headers(provider)
    body = %{model: model.name, input: texts}

    HTTP.post_json(Provider.embeddings_url(provider), body, headers, [])
    |> parse_embeddings_response()
  end

  # Response parsing functions

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
            # Tool-call arguments come from the model and may be
            # malformed JSON. Treat decode errors as empty arguments
            # rather than crashing the whole response. Other exceptions
            # (FunctionClauseError, etc.) propagate so real bugs are
            # not silently swallowed.
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

  defp parse_embeddings_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    embeddings =
      body
      |> Map.get("data", [])
      |> Enum.map(& &1["embedding"])

    {:ok, embeddings}
  end

  defp parse_embeddings_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, inspect(body))}
  end

  defp parse_embeddings_response({:error, reason}), do: {:error, reason}

  defp parse_ollama_embedding({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body["embedding"] || []}
  end

  defp parse_ollama_embedding({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, inspect(body))}
  end

  defp parse_ollama_embedding({:error, reason}), do: {:error, reason}

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
