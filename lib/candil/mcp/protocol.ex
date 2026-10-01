defmodule Candil.MCP.Protocol do
  @moduledoc """
  Which revision of the Model Context Protocol this speaks.

  ## `2025-11-25`, not `2024-11-05`

  The three previous design documents in this repository specified
  `2024-11-05`. That is two generations behind and costs three concrete
  things, each verified against the specification rather than assumed:

  1. **The handshake is not optional.** `initialize` runs first, and the
     client states the revision it supports. The server answers with its own
     and the session continues from there. A `2024-11-05` server treats the
     first `tools/list` as the first message of the session.

  2. **Every HTTP request after `initialize` carries
     `mcp-protocol-version`.** A request without it is assumed to be
     `2025-03-26`. A request with a version the server does not implement is
     a `400`, not a best guess.

  3. **There is no JSON-RPC batching.** It was removed in `2025-06-18`.
     Sending an array of requests is an error. A server that accepts an array
     is talking to a revision it claims not to.

  `supported?/1` and `negotiate/1` exist so a mismatch is an explicit
  decision at the boundary rather than a series of confusing failures later.
  """

  @version Mix.Project.config()[:version]
  @latest "2025-11-25"

  # Newest first. This is what a client may present that we can still serve.
  @supported ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  @doc """
  The revision this server speaks.
  """
  @spec version() :: String.t()
  def version, do: @latest

  @doc """
  The revisions this server can serve, newest first.
  """
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc """
  The revision assumed for an HTTP request with no version header.
  """
  @spec default_http_version() :: String.t()
  def default_http_version, do: "2025-03-26"

  @doc """
  Whether a revision can be served.
  """
  @spec supported?(String.t()) :: boolean()
  def supported?(revision), do: revision in @supported

  @doc """
  The revision to answer with, given what the client presented.

  A client that offers a revision we support gets it back. A client that
  offers one we do not gets an error rather than a silent downgrade: a
  client silently moved to a revision it did not ask for will fail in ways
  that look like server bugs.

  ## Examples

      iex> Candil.MCP.Protocol.negotiate("2025-06-18")
      {:ok, "2025-06-18"}

      iex> Candil.MCP.Protocol.negotiate(nil)
      {:ok, "2025-03-26"}

      iex> Candil.MCP.Protocol.negotiate("1999-01-01")
      {:error, :unsupported_version}
  """
  @spec negotiate(String.t() | nil) :: {:ok, String.t()} | {:error, :unsupported_version}
  def negotiate(nil), do: {:ok, default_http_version()}

  def negotiate(requested) when is_binary(requested) do
    if supported?(requested), do: {:ok, requested}, else: {:error, :unsupported_version}
  end

  @doc """
  Checks an HTTP request's version header.

  Returns `{:ok, revision}` when the request may proceed, and a `400`-shaped
  error when it may not.
  """
  @spec check_http_header(String.t() | nil) ::
          {:ok, String.t()} | {:error, {:bad_request, String.t()}}
  def check_http_header(nil), do: {:ok, default_http_version()}

  def check_http_header(revision) do
    case negotiate(revision) do
      {:ok, negotiated} ->
        {:ok, negotiated}

      {:error, :unsupported_version} ->
        message =
          "#{version_header()} #{revision} is not supported. Supported: #{Enum.join(@supported, ", ")}"

        {:error, {:bad_request, message}}
    end
  end

  @doc """
  The JSON-RPC methods a server answers. Batching is absent because the
  protocol removed it.
  """
  @spec server_methods() :: [String.t()]
  def server_methods do
    ~w(initialize tools/list tools/call resources/list resources/read prompts/list prompts/get)
  end

  @doc """
  The JSON-RPC methods a client sends.
  """
  @spec client_methods() :: [String.t()]
  def client_methods, do: server_methods()

  @doc """
  The header carrying the negotiated revision on HTTP.
  """
  @spec version_header() :: String.t()
  def version_header, do: "MCP-Protocol-Version"

  @doc """
  The result of `initialize`, announcing our revision and capabilities.
  """
  @spec initialize_result() :: map()
  def initialize_result do
    %{
      jsonrpc: "2.0",
      id: 1,
      result: %{
        protocolVersion: version(),
        capabilities: %{tools: %{}, resources: %{}},
        serverInfo: %{name: "candil", version: @version}
      }
    }
  end

  @doc """
  Whether a payload is a JSON-RPC batch, which the protocol no longer allows.

  ## Examples

      iex> Candil.MCP.Protocol.batch?([%{id: 1}])
      true

      iex> Candil.MCP.Protocol.batch?(%{id: 1})
      false
  """
  @spec batch?(term()) :: boolean()
  def batch?(payload) when is_list(payload), do: true
  def batch?(_payload), do: false

  @doc """
  The error a batch gets, which is the only answer it can get.
  """
  @spec batch_error() :: map()
  def batch_error do
    %{
      jsonrpc: "2.0",
      id: nil,
      error: %{
        code: -32_600,
        message: "JSON-RPC batching was removed in MCP 2025-06-18. Send one request per message."
      }
    }
  end
end
