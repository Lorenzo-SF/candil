defmodule Candil.Gateway do
  @moduledoc """
  An OpenAI-compatible HTTP server in front of the whole catalogue.

  This is what makes Candil usable without writing Elixir. `opencode`, the
  `openai-python` client, `curl`, anything that speaks the OpenAI API: point
  it at `http://127.0.0.1:7777/v1` and it works.

  ## The consumer is in the path

  Every route has a `/c/:consumer` prefix as well as a bare form:

      POST /c/opencode/v1/chat/completions
      POST /v1/chat/completions          → consumer "default"

  Without it, two consumers sharing one gateway would share a default model
  and fight over it. The prefix is what lets a gateway serve several clients
  without configuration colliding.

  ## `model: "auto"` is opt-in per request

  A request naming a concrete model skips the router entirely, so a client
  keeps working if the router decides badly. A request with `"auto"` goes
  through it. Both are supported on purpose: a router you cannot bypass is a
  router whose mistakes you cannot work around.

  ## Auth

  `auth = "none"` by default, and it only listens on loopback. Setting
  `auth = "api_key"` requires a key on every request, compared in constant
  time. JWT is not here and does not belong in v4: it is a few hundred lines,
  nobody asked for it, and `auth = "none"` on loopback is the honest default
  for a local process. Adding it later is one more clause in `Auth`.
  """

  alias Candil.Error
  alias Candil.Gateway.{Auth, Endpoint}

  @type auth_mode :: :none | :api_key

  @doc """
  Validates the gateway configuration.

  Returns `{:error, :not_implemented}` once the configuration is sound,
  because the HTTP listener is phase 8. It does **not** return a pid: a
  gateway that answers "started" and then refuses every connection is worse
  than one that says it is not listening yet.

  Returns `{:error, reason}` when the configuration is wrong, which is the
  part worth having now.
  """
  @spec start(keyword()) :: {:error, term()}
  def start(opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 7777)

    mode = Keyword.get(opts, :auth, :none)
    keys = Keyword.get(opts, :api_keys, [])

    # Validate the auth configuration even though the listener is not here
    # yet: `candil gateway start` should say "auth = \"api_key\" needs at least
    # one key" rather than binding a port and returning 401 to everything.
    case Auth.validate(mode, keys) do
      {:ok, _mode} ->
        {:error,
         Error.not_implemented("Candil.Gateway.Endpoint.listen/4",
           host: host,
           port: port
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The full route table: one map per method and path.

  The handlers are named but not written; they land with the listener in
  phase 8. The table is real now so the start banner and the handler tests
  have something to iterate over.
  """
  @spec routes() :: [Endpoint.route()]
  defdelegate routes(), to: Endpoint

  @doc """
  Turns a router error into the JSON body an OpenAI client expects.

  A client that gets an HTML error page or an Elixir crash dump has no way to
  tell a routing problem from a network problem, and will retry the wrong
  thing.

  ## Examples

      iex> {:error, body} = Candil.Gateway.error_body(:no_models_for_consumer)
      iex> {body.error.type, body.error.param, body.error.code}
      {"invalid_request_error", nil, nil}
  """
  @spec error_body(term()) :: {:error, map()}
  def error_body(:no_models_for_consumer) do
    openai_error(
      "no models are configured for this consumer. " <>
        "Check [consumer.<name>] in candil.toml.",
      "invalid_request_error"
    )
  end

  def error_body({:unknown_model, alias}) do
    openai_error("no model named #{inspect(alias)} is registered", "invalid_request_error")
  end

  def error_body({:unknown_engine, alias}) do
    openai_error("no engine named #{inspect(alias)} is registered", "invalid_request_error")
  end

  def error_body({:unknown_provider, alias}) do
    openai_error("no provider named #{inspect(alias)} is registered", "invalid_request_error")
  end

  def error_body(%Error{reason: reason, context: context}) do
    openai_error("#{inspect(reason)}: #{inspect(context)}", "server_error")
  end

  def error_body(other) do
    openai_error(inspect(other), "server_error")
  end

  defp openai_error(message, type) do
    {:error, %{error: %{message: message, type: type, param: nil, code: nil}}}
  end

  @doc """
  The chat-completions response envelope, for handler tests.
  """
  @spec chat_completion(binary(), binary(), integer()) :: map()
  def chat_completion(id, content, created \\ 0) do
    %{
      id: id,
      object: "chat.completion",
      created: created,
      model: "",
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: content},
          finish_reason: "stop"
        }
      ],
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }
  end
end
