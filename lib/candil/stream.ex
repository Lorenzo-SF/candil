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
    base_url =
      Keyword.get(opts, :base_url) || Engine.base_url(model_alias)

    case base_url do
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
          Engine.auth_headers_for(model_alias),
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
          :ok | {:error, term()}
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
    initial_state = %{buffer: "", done: false, error: nil}

    # P0-1: use Task.start (unlinked) instead of Task.start_link.
    # If the caller dies the stream task doesn't propagate the EXIT
    # signal to the streaming HTTP task, allowing the resource
    # teardown below to shut it down cleanly via Port.close.
    #
    # Y el pid de quien consume se captura **aqui**, no dentro del Task:
    # dentro del Task, `self()` es el Task, y los chunks se quedaban en su inbox
    # mientras quien habia pedido el stream esperaba a mensajes que no iban a
    # llegar nunca.
    consumer = self()

    {:ok, task} =
      Task.start(fn ->
        case HTTP.post_streaming(
               url,
               body,
               headers,
               [timeout_ms: timeout, retry: false],
               into: receive_inbox(consumer, receive_timeout)
             ) do
          # `{:ok, _}` ya avisó por el `receive_inbox/2`: el `:done` del
          # adapter llegó a `consumer`.
          {:ok, _} ->
            :ok

          # Y si fallo, **el motivo se propaga**. Antes no se propagaba nada y
          # quien esperaba se enteraba de que habia un problema porque se le
          # acababa el tiempo: un `:timeout` que no era un timeout. El Task es
          # el unico que sabe por que fallo, asi que el aviso sale de ahi.
          {:error, reason} ->
            send(consumer, {:sse_error, reason, self()})
        end
      end)

    # Y esto **no** es un `Stream.resource/3`. Aqui no se produce una lista: se
    # produce un efecto, el `callback/1`, y lo que importa es quien recibe. En
    # `resource/3` el elemento emitido y el acumulador son la misma cosa, asi
    # que el estado del parser acababa siendo elemento de la lista y
    # `Enum.take_while` reventaba al iterarlo.
    resultado = recibir(initial_state, parse_fn, callback, receive_timeout + timeout)

    Process.exit(task, :kill)

    case resultado do
      %{error: nil} -> :ok
      %{error: reason} -> {:error, reason}
    end
  end

  @doc false
  @spec recibir(map(), (binary() -> chunk() | nil), stream_callback(), pos_integer()) :: map()
  defp recibir(%{done: true} = state, _parse_fn, _callback, _limite), do: state

  defp recibir(state, parse_fn, callback, limite) do
    receive do
      {:sse_data, data} ->
        recibir(consume_data(data, state, parse_fn, callback), parse_fn, callback, limite)

      {:sse_done, _pid} ->
        %{state | done: true}

      {:sse_error, reason, _pid} ->
        %{state | done: true, error: reason}
    after
      limite -> %{state | done: true, error: :timeout}
    end
  end

  # Accumulate a fresh chunk into the parser's buffer and yield complete
  # events to the callback. Stateful across calls (handles arbitrary
  # TCP chunks that split an SSE event across reads). Returns the
  # updated parser state.
  @spec consume_data(binary(), map(), (binary() -> chunk() | nil), stream_callback()) :: map()
  defp consume_data(_data, %{done: true} = state, _parse_fn, _callback) do
    state
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
    # Devuelve **el acumulador**, no `""`. Lo que este callback devuelve es el
    # acumulador de Finch —`Finch.stream/5` lo envuelve en `{:cont, _}`—, y
    # devolver una cadena vacia lo llenaba de `" "` a cada chunk. Aqui no se lee,
    # pero un acumulador que no es un acumulador es una trampa para quien lo lea.
    fn
      {:data, data}, acc ->
        send(consumer_pid, {:sse_data, data})
        acc

      :done, acc ->
        send(consumer_pid, {:sse_done, self()})
        acc

      {:error, reason}, acc ->
        send(consumer_pid, {:sse_error, reason, self()})
        acc
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
