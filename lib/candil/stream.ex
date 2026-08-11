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
    receive_timeout = Keyword.get(opts, :receive_timeout_ms, 30_000)
    initial_state = %{buffer: "", done: false}

    {:ok, task} =
      Task.start_link(fn ->
        HTTP.post_streaming(
          url,
          body,
          headers,
          [timeout_ms: timeout, retry: false],
          into: receive_inbox(self(), receive_timeout)
        )
      end)

    result =
      Stream.resource(
        fn -> initial_state end,
        fn state ->
          receive do
            {:sse_data, data} ->
              consume_data(data, state, parse_fn, callback)

            {:sse_done, _pid} ->
              {:halt, %{state | done: true}}

            {:sse_error, reason, _pid} ->
              {:halt, %{state | done: true, error: reason}}
          after
            receive_timeout + timeout ->
              {:halt, %{state | done: true, error: :timeout}}
          end
        end,
        fn _ -> :ok end
      )
      |> Enum.take_while(fn _ -> true end)

    Process.exit(task, :kill)

    case result do
      [] -> :ok
      _ -> :ok
    end
  end

  # Accumulate a fresh chunk into the parser's buffer and yield complete
  # events to the callback. Stateful across calls (handles arbitrary
  # TCP chunks that split an SSE event across reads). Returns the
  # updated parser state.
  @spec consume_data(binary(), map(), (binary() -> chunk() | nil), stream_callback()) ::
          {:cont, map()} | {:halt, map()}
  defp consume_data(_data, %{done: true} = state, _parse_fn, _callback) do
    {:halt, state}
  end

  defp consume_data(data, state, parse_fn, callback) do
    buffer = state.buffer <> data
    {events, rest} = extract_sse_events(buffer)
    new_state = %{state | buffer: rest}

    Enum.reduce_while(events, new_state, fn event, st ->
      case parse_fn.(event) do
        nil ->
          {:cont, st}

        %{done: false} = chunk ->
          callback.(chunk)
          {:cont, st}

        %{done: true} = chunk ->
          callback.(chunk)
          {:halt, %{st | done: true}}
      end
    end)
  end

  # Split a buffer into complete SSE events and the leftover partial
  # tail. An SSE event is `data: ...\n\n`; we accept both LF and CRLF
  # line terminators.
  @doc false
  @spec extract_sse_events(binary()) :: {[binary()], binary()}
  def extract_sse_events(buffer) do
    {events, rest} = do_split_events(buffer, [], "")

    # Drop comment lines (`:` prefix) per the SSE spec.
    events =
      Enum.map(events, fn event ->
        event
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(&1, ":"))
        |> Enum.join("\n")
      end)
      |> Enum.reject(&(&1 == ""))

    {events, rest}
  end

  defp do_split_events("", acc, current), do: {Enum.reverse(acc), current}

  # CRLF + LF blank-line terminator: `\r\n\r\n` or `\r\n\n` or `\n\r\n`
  defp do_split_events("\r\n\r\n" <> rest, acc, current), do: finish_event(rest, acc, current)
  defp do_split_events("\r\n\n" <> rest, acc, current), do: finish_event(rest, acc, current)
  defp do_split_events("\n\r\n" <> rest, acc, current), do: finish_event(rest, acc, current)

  # Bare LF blank-line terminator.
  defp do_split_events("\n\n" <> rest, acc, current), do: finish_event(rest, acc, current)

  # A bare CR is a no-op (consumed as whitespace) so it doesn't get
  # appended to the current line and confuse later parsing.
  defp do_split_events("\r" <> rest, acc, current), do: do_split_events(rest, acc, current)

  defp do_split_events("\n" <> rest, acc, current) do
    do_split_events(rest, acc, current <> "\n")
  end

  defp do_split_events(<<c::utf8, rest::binary>>, acc, current) do
    do_split_events(rest, acc, current <> <<c::utf8>>)
  end

  defp finish_event(rest, acc, current) do
    cleaned =
      current
      |> String.trim()
      |> String.trim_leading("data:")
      |> String.trim()

    do_split_events(rest, [cleaned | acc], "")
  end

  # Build the `into:` callback that pushes events into the consumer's
  # mailbox. The mailbox is the consumer's own process — i.e. the
  # caller of `do_stream/6`. This way `receive` in `Enum.take_while/2`
  # blocks until data arrives, with backpressure: while the consumer
  # is busy, AperoHTTP's stream buffers up to its internal limit.
  @spec receive_inbox(pid(), pos_integer()) :: (... -> any())
  defp receive_inbox(consumer_pid, _idle_timeout) do
    fn
      {:data, data}, _acc -> send(consumer_pid, {:sse_data, data}); ""
      :done, _acc -> send(consumer_pid, {:sse_done, self()}); ""
      {:error, reason}, _acc -> send(consumer_pid, {:sse_error, reason, self()}); ""
    end
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
