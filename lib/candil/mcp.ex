defmodule Candil.MCP do
  @moduledoc """
  Model Context Protocol, as a server and as a client.

  The revision and its rules live in `Candil.MCP.Protocol`. This module is the
  facade over transports, and the transports land in phase 9.

  ## Why the default transport is stdio

  Because that is how every MCP host launches a server: as a subprocess and
  over stdin and stdout. HTTP is the other option, and it is not the default
  because a stdio server has no port to collide with, no token to leak and
  nothing listening after the host goes away.

  ## Tools come from the registry, not from a list

  `serve/1` takes `:registered` and exposes whatever `Candil.Tool` has. A
  consumer that defines its own tools therefore gets them served without
  Candil knowing anything about them — which is how a vault of 29 tools gets
  exposed by a client that knows nothing about vaults.
  """

  alias Candil.{Error, MCP}

  @doc """
  Starts a server.

  Returns `{:error, :not_implemented}`: the transports are phase 9, and the
  version negotiation in `Candil.MCP.Protocol` is already testable without
  them.
  """
  @spec serve(keyword()) :: {:ok, pid()} | {:error, term()}
  def serve(opts \\ []) do
    _ = opts
    {:error, Error.not_implemented("Candil.MCP.serve/1", phase: 9)}
  end

  @doc """
  Connects to a server.

  Not implemented until phase 9.
  """
  @spec connect(keyword()) :: {:ok, map()} | {:error, term()}
  def connect(opts \\ []) do
    _ = opts
    {:error, Error.not_implemented("Candil.MCP.connect/1", phase: 9)}
  end

  @doc """
  The transports a server or client can use.
  """
  @spec transports() :: [:stdio | :http]
  def transports, do: [:stdio, :http]

  @doc """
  Which tools a `serve/1` call would expose.

  ## Examples

      iex> Candil.MCP.resolve_tools(:registered)
      :registered

      iex> Candil.MCP.resolve_tools([MyApp.Weather])
      [MyApp.Weather]
  """
  @spec resolve_tools(:registered | [module()]) :: :registered | [module()]
  def resolve_tools(:registered), do: :registered
  def resolve_tools(tools) when is_list(tools), do: tools

  @doc """
  The wire shape of a tool, as `tools/list` returns it.

  ## Examples

      iex> Candil.MCP.tool_wire(%{name: "weather", description: "d", schema: %{}})
      %{name: "weather", description: "d", inputSchema: %{}}
  """
  @spec tool_wire(map()) :: map()
  def tool_wire(%{name: name, description: description, schema: schema}) do
    %{name: name, description: description, inputSchema: schema}
  end

  @doc """
  The wire shape of a `tools/call` result.

  The content is a list of typed blocks, not a bare string, because that is
  what every MCP client expects to iterate.
  """
  @spec call_result(term()) :: map()
  def call_result(result) do
    text = if is_binary(result), do: result, else: inspect(result)
    %{content: [%{type: "text", text: text}]}
  end

  @doc """
  The JSON-RPC error for a tool that raised.

  `-32603` is the generic server error. A failing tool must not take the
  server down: the host has other tools to call and the failure belongs to
  the call, not to the session.
  """
  @spec tool_error(Exception.t(), String.t()) :: map()
  def tool_error(exception, tool_name) do
    %{
      jsonrpc: "2.0",
      id: nil,
      error: %{
        code: -32_603,
        message: "tool #{inspect(tool_name)} failed: #{Exception.message(exception)}",
        data: %{tool: tool_name, reason: inspect(exception.__struct__)}
      }
    }
  end

  @doc """
  The protocol revision. Delegates, so there is one source of truth.
  """
  @spec version() :: String.t()
  defdelegate version(), to: MCP.Protocol

  @doc """
  The supported revisions.
  """
  @spec supported_versions() :: [String.t()]
  defdelegate supported_versions(), to: MCP.Protocol, as: :supported
end
