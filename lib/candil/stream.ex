defmodule Candil.Stream do
  @moduledoc """
  Server-Sent Events (SSE) streaming for LLM inference.

  Streams tokens from local engines and remote providers as they are
  generated, calling a user-supplied callback for each chunk.

  ## Usage

      Candil.Stream.chat(:llama3, [
        %{role: "user", content: "Write a haiku about Elixir"}
      ], fn chunk ->
        IO.write(chunk.content)
      end)

  The callback receives a `chunk()` map:

      %{content: "token", finish_reason: nil | "stop" | "length", done: false}

  When streaming ends the callback is called once more with `done: true`.

  ## Provider support

  OpenAI, Anthropic, Ollama, OpenAI-compatible, Azure OpenAI and local llama-server.
  """

  alias Candil.{Engine, Error, HTTP, Inference, Model, Provider, RequestBuilder}

  @type chunk :: %{
          content: binary(),
          finish_reason: binary() | nil,
          done: boolean()
        }

  @type stream_callback :: (chunk() -> any())

  @doc """
  Streams a chat completion from a running local engine identified by alias.
  """
  @spec chat(atom(), [Inference.message()], stream_callback(), keyword()) ::
          :ok | {:error, Error.t()}
  def chat(model_alias, messages, callback, opts \\ [])
      when is_atom(model_alias) and is_function(callback, 1) do
    case Engine.base_url(model_alias) do
      nil ->
        {:error, Error.engine_not_running(model_alias)}

      base_url ->
        body =
          RequestBuilder.build_openai_body(
            to_string(model_alias),
            messages,
            Keyword.put(opts, :stream, true)
          )

        do_stream(
          "#{base_url}/v1/chat/completions",
          body,
          [],
          &parse_openai_chunk/1,
          callback,
          opts
        )
    end
  end

  @doc """
  Streams a chat completion from a remote provider.
  """
  @spec chat(Model.t(), Provider.t(), [Inference.message()], stream_callback(), keyword()) ::
          :ok | {:error, Error.t()}
  def chat(%Model{} = model, %Provider{type: :anthropic} = provider, messages, callback, opts)
      when is_function(callback, 1) do
    body =
      RequestBuilder.build_anthropic_body(
        model.name,
        messages,
        Keyword.put(opts, :stream, true)
      )

    headers = Provider.auth_headers(provider)

    do_stream(
      Provider.chat_url(provider),
      body,
      headers,
      &parse_anthropic_chunk/1,
      callback,
      opts
    )
  end

  def chat(%Model{} = model, %Provider{type: :ollama} = provider, messages, callback, opts)
      when is_function(callback, 1) do
    body =
      RequestBuilder.build_ollama_chat_body(
        model.name,
        messages,
        Keyword.put(opts, :stream, true)
      )

    headers = Provider.auth_headers(provider)
    do_stream(Provider.chat_url(provider), body, headers, &parse_ollama_chunk/1, callback, opts)
  end

  def chat(%Model{} = model, %Provider{type: :openai} = provider, messages, callback, opts)
      when is_function(callback, 1) do
    body =
      RequestBuilder.build_openai_body(
        model.name,
        messages,
        Keyword.put(opts, :stream, true)
      )

    headers = Provider.auth_headers(provider)
    do_stream(Provider.chat_url(provider), body, headers, &parse_openai_chunk/1, callback, opts)
  end

  def chat(
        %Model{} = model,
        %Provider{type: :openai_compatible} = provider,
        messages,
        callback,
        opts
      )
      when is_function(callback, 1) do
    body =
      RequestBuilder.build_openai_body(
        model.name,
        messages,
        Keyword.put(opts, :stream, true)
      )

    headers = Provider.auth_headers(provider)
    do_stream(Provider.chat_url(provider), body, headers, &parse_openai_chunk/1, callback, opts)
  end

  def chat(%Model{} = model, %Provider{type: :azure_openai} = provider, messages, callback, opts)
      when is_function(callback, 1) do
    body =
      RequestBuilder.build_openai_body(
        model.name,
        messages,
        Keyword.put(opts, :stream, true)
      )

    headers = Provider.auth_headers(provider)
    do_stream(Provider.chat_url(provider), body, headers, &parse_openai_chunk/1, callback, opts)
  end

  defp do_stream(url, body, headers, parse_fn, callback, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    result =
      HTTP.post_streaming(
        url,
        body,
        headers,
        [timeout_ms: timeout, retry: false],
        into: fn
          {:data, data}, acc ->
            data
            |> split_sse_lines()
            |> Enum.reduce_while(acc, fn line, state ->
              case parse_fn.(line) do
                nil ->
                  {:cont, state}

                %{done: false} = chunk ->
                  callback.(chunk)
                  {:cont, state}

                %{done: true} = chunk ->
                  callback.(chunk)
                  {:halt, :done}
              end
            end)
            |> then(fn
              :done -> {:halt, :done}
              state -> {:cont, state}
            end)

          :done, _acc ->
            {:halt, :done}
        end
      )

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Error.wrap(reason)}
    end
  end

  defp split_sse_lines(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn line -> line |> String.trim_leading("data:") |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_openai_chunk("[DONE]"), do: %{content: "", finish_reason: "stop", done: true}

  defp parse_openai_chunk(json) do
    case Jason.decode(json) do
      {:ok, %{"choices" => [choice | _]}} ->
        content = get_in(choice, ["delta", "content"]) || ""
        finish_reason = choice["finish_reason"]
        %{content: content, finish_reason: finish_reason, done: finish_reason != nil}

      _ ->
        nil
    end
  end

  defp parse_anthropic_chunk(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
        %{content: text, finish_reason: nil, done: false}

      {:ok, %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}}} ->
        %{content: "", finish_reason: reason, done: true}

      {:ok, %{"type" => "message_stop"}} ->
        %{content: "", finish_reason: "stop", done: true}

      _ ->
        nil
    end
  end

  defp parse_ollama_chunk(json) do
    case Jason.decode(json) do
      {:ok, %{"message" => %{"content" => content}, "done" => done}} ->
        %{content: content, finish_reason: if(done, do: "stop", else: nil), done: done}

      _ ->
        nil
    end
  end
end
