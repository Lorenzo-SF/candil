defmodule Candil.MCP.Server do
  @moduledoc """
  Servidor MCP (JSON-RPC 2.0) sobre stdio.

  Expone las herramientas registradas en `Candil.Tool` —incluidas las de
  terceros registradas con `Candil.MCP.Tool`— a cualquier host de LLM.

  ## El criterio de aceptación

  Un tercero registra una herramienta y `tools/list` la devuelve y
  `tools/call` la ejecuta, sin tocar `lib/candil/`. Ese es el test que decide
  si la fase 7 está hecha.
  """

  use GenServer

  alias Candil.MCP
  alias Candil.Tool

  @protocol_version "2025-11-25"

  @doc "Starts the server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Processes a single JSON-RPC request (as a map) and returns the response
  map. Synchronous, testable without stdio.
  """
  @spec handle_request(GenServer.server(), map()) :: map()
  def handle_request(server, request) when is_map(request) do
    GenServer.call(server, {:request, request})
  end

  @doc """
  Runs the server over stdio: reads JSON-RPC requests from stdin, writes
  responses to stdout. Blocks until EOF.
  """
  @spec run_stdio(keyword()) :: :ok
  def run_stdio(opts \\ []) do
    {:ok, server} = start_link(opts)

    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      line = String.trim(line)

      if line != "" do
        case Jason.decode(line) do
          {:ok, request} ->
            response = handle_request(server, request)
            IO.puts(Jason.encode!(response))

          {:error, _} ->
            IO.puts(
              Jason.encode!(%{
                jsonrpc: "2.0",
                id: nil,
                error: %{code: -32_700, message: "Parse error"}
              })
            )
        end
      end
    end)

    GenServer.stop(server)
    :ok
  end

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:request, request}, _from, state) do
    response = dispatch(request)
    {:reply, response, state}
  end

  # ── dispatch ─────────────────────────────────────────────────────────────

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = req) do
    params = Map.get(req, "params", %{})
    result = dispatch_method(method, params)

    case result do
      {:ok, r} -> %{jsonrpc: "2.0", id: id, result: r}
      {:error, code, message} -> %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
    end
  end

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = req) do
    # notification (no id)
    params = Map.get(req, "params", %{})
    _ = dispatch_method(method, params)
    nil
  end

  defp dispatch(_),
    do: %{jsonrpc: "2.0", id: nil, error: %{code: -32_600, message: "Invalid Request"}}

  defp dispatch_method("initialize", _params) do
    {:ok,
     %{
       protocolVersion: @protocol_version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "candil", version: "4.0.0"}
     }}
  end

  defp dispatch_method("tools/list", _params) do
    tools =
      Tool.list()
      |> Enum.map(fn tool ->
        MCP.tool_wire(%{name: tool.name, description: tool.description, schema: tool.schema})
      end)

    {:ok, %{tools: tools}}
  end

  defp dispatch_method("tools/call", %{"name" => name, "arguments" => args}) do
    result =
      try do
        Tool.call(name, args)
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, result} ->
        {:ok, MCP.call_result(result)}

      {:error, %Candil.Error{} = err} ->
        {:error, -32_603, inspect(err.reason)}

      {:error, e} when is_exception(e) ->
        {:error, -32_603, "tool #{name} failed: #{Exception.message(e)}"}

      {:error, reason} ->
        {:error, -32_603, inspect(reason)}
    end
  end

  defp dispatch_method("tools/call", %{"name" => name}) do
    dispatch_method("tools/call", %{"name" => name, "arguments" => %{}})
  end

  defp dispatch_method(method, _params) do
    {:error, -32_601, "Method not found: #{method}"}
  end
end
