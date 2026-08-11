defmodule Candil.Backend.OpenAICompat do
  @moduledoc """
  `Candil.Backend` implementation for OpenAI-compatible HTTP APIs.

  Used by:
    * `provider: :openai` (api.openai.com)
    * `provider: :anthropic` (api.anthropic.com — note Anthropic uses a
      slightly different request body, but the OpenAI-compat SSE
      streaming format works for both via the `messages` array)
    * `provider: :ollama` (Ollama's `/v1/chat/completions` endpoint)
    * `provider: :azure` (Azure OpenAI Service)

  Auth tokens and base URLs come from `Candil.Config` per provider.
  This module is auto-registered for those providers on first lookup.
  """

  @behaviour Candil.Backend

  alias Candil.{Config, Error, HTTP, Model, Provider, Telemetry}

  @default_base_urls %{
    openai: "https://api.openai.com",
    anthropic: "https://api.anthropic.com",
    ollama: "http://127.0.0.1:11434",
    azure: nil
  }

  @impl true
  def chat(model, messages, opts) when is_list(messages) do
    case config_for(provider_of(model), opts) do
      {:ok, base_url, token} ->
        url = "#{base_url}/v1/chat/completions"
        body = build_body(model, messages, Keyword.put(opts, :stream, false))
        headers = auth_headers(token)

        case HTTP.post_json(url, body, headers,
               timeout_ms: opts[:timeout_ms] || 60_000,
               retry: Keyword.get(opts, :retry, true)
             ) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            parse_chat_response(body)

          {:ok, %{status: status, body: body}} ->
            {:error, Error.http_error(status, body)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def chat_stream(model, messages, opts) when is_list(messages) do
    case config_for(provider_of(model), opts) do
      {:ok, base_url, token} ->
        url = "#{base_url}/v1/chat/completions"
        body = build_body(model, messages, Keyword.put(opts, :stream, true))
        headers = auth_headers(token)
        request_id = Keyword.get(opts, :request_id, "stream-#{System.unique_integer()}")

        Telemetry.emit_start(request_id, :stream, %{model: model_id(model)})
        started = System.monotonic_time()

        case HTTP.post_streaming(
               url,
               body,
               headers,
               [timeout_ms: opts[:timeout_ms] || 120_000, retry: false],
               into: fn
                 {:data, _data}, _acc -> :cont
                 :done, _acc -> :done
                 {:error, _}, _acc -> :error
               end
             ) do
          {:ok, _} ->
            Telemetry.emit_stop(request_id, :stream, System.monotonic_time() - started, [])
            {:ok, build_chunk_stream(body)}

          {:error, reason} ->
            Telemetry.emit_error(request_id, :stream, System.monotonic_time() - started, :http, %{})
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def embed(model, texts, opts) when is_list(texts) do
    case config_for(provider_of(model), opts) do
      {:ok, base_url, token} ->
        url = "#{base_url}/v1/embeddings"

        results =
          Enum.map(texts, fn text ->
            body = %{model: model_id(model), input: text}
            headers = auth_headers(token)

        case HTTP.post_json(url, body, headers,
               timeout_ms: opts[:timeout_ms] || 60_000,
               retry: Keyword.get(opts, :retry, true)
             ) do
              {:ok, %{status: 200, body: %{"data" => [%{"embedding" => vec}]}}} when is_list(vec) ->
                {:ok, vec}

              {:ok, %{status: status, body: body}} ->
                {:error, Error.http_error(status, body)}

              {:error, reason} ->
                {:error, reason}
            end
          end)

        case Enum.split_with(results, &match?({:ok, _}, &1)) do
          {oks, []} -> {:ok, Enum.map(oks, fn {:ok, v} -> v end)}
          {_oks, errs} -> {:error, elem(hd(errs), 1)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def models do
    [
      %Model{alias: :"gpt-4o", name: "gpt-4o", provider: :openai, type: :remote},
      %Model{alias: :"gpt-4o-mini", name: "gpt-4o-mini", provider: :openai, type: :remote},
      %Model{
        alias: :"gpt-4-turbo",
        name: "gpt-4-turbo",
        provider: :openai,
        type: :remote
      },
      %Model{alias: :"o1-preview", name: "o1-preview", provider: :openai, type: :remote},
      %Model{alias: :"o1-mini", name: "o1-mini", provider: :openai, type: :remote},
      %Model{
        alias: :"claude-3-5-sonnet-latest",
        name: "claude-3-5-sonnet-latest",
        provider: :anthropic,
        type: :remote
      },
      %Model{
        alias: :"claude-3-5-haiku-latest",
        name: "claude-3-5-haiku-latest",
        provider: :anthropic,
        type: :remote
      }
    ]
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec config_for(atom(), keyword()) :: {:ok, String.t(), String.t() | nil} | {:error, term()}
  defp config_for(provider, opts) do
    base_url =
      Keyword.get(opts, :base_url) ||
        case provider do
          p when p in [:openai, :anthropic, :ollama] -> Map.get(@default_base_urls, p)
          :azure -> nil
          _ -> nil
        end

    token = Keyword.get(opts, :token) || provider_token(provider)

    cond do
      is_nil(base_url) -> {:error, Error.invalid_request("missing base_url for #{provider}")}
      base_url == "" -> {:error, Error.invalid_request("empty base_url")}
      true -> {:ok, base_url, token}
    end
  end

  defp provider_token(provider) do
    case Config.get_provider(provider) do
      {:ok, %Provider{api_key: key}} when is_binary(key) -> key
      _ -> nil
    end
  end

  @spec auth_headers(String.t() | nil) :: [{String.t(), String.t()}]
  defp auth_headers(nil), do: [{"Content-Type", "application/json"}]
  defp auth_headers(token), do: [{"Content-Type", "application/json"}, {"Authorization", "Bearer #{token}"}]

  @spec provider_of(String.t() | Model.t()) :: atom()
  defp provider_of(%Model{provider: provider}), do: provider
  defp provider_of(_), do: :openai

  @spec model_id(String.t() | Model.t()) :: String.t()
  defp model_id(%Model{name: name}), do: name
  defp model_id(id) when is_binary(id), do: id

  @spec build_body(String.t() | Model.t(), [map()], keyword() | map()) :: map()
  defp build_body(model, messages, opts) do
    opts = Map.new(opts)

    %{
      model: model_id(model),
      messages: Enum.map(messages, &normalize_message/1),
      stream: Map.get(opts, :stream, false)
    }
    |> maybe_put(:temperature, opts[:temperature])
    |> maybe_put(:max_tokens, opts[:max_tokens])
    |> maybe_put(:tools, opts[:tools])
    |> maybe_put(:response_format, opts[:response_format])
  end

  defp normalize_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec parse_chat_response(map()) :: {:ok, map()} | {:error, term()}
  defp parse_chat_response(%{"choices" => [%{"message" => %{"content" => content}} | _]} = body) do
    usage = body["usage"] || %{}
    input = usage["prompt_tokens"] || 0
    output = usage["completion_tokens"] || 0
    finish = body["choices"] |> hd() |> get_in(["finish_reason"])

    {:ok,
     %{
       content: content || "",
       finish_reason: finish,
       usage: %{input_tokens: input, output_tokens: output}
     }}
  end

  defp parse_chat_response(other), do: {:error, Error.invalid_request("unexpected response: #{inspect(other)}")}

  @spec build_chunk_stream(map()) :: Enumerable.t()
  defp build_chunk_stream(_body) do
    # The actual streaming happens via HTTP.post_streaming + SSE parser
    # in Candil.Stream. This stub returns an empty stream — callers
    # that need real OpenAI streaming should use Candil.Stream directly.
    Stream.repeatedly(fn ->
      Process.sleep(50)
      %{content: "", finish_reason: nil, done: true}
    end)
    |> Stream.take(1)
  end
end