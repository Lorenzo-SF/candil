defmodule Candil.MCP.AcceptanceTest do
  @moduledoc """
  El criterio de aceptación de la fase 7: un tercero define un módulo con el
  behaviour y funciona sin tocar Candil.
  """

  use ExUnit.Case, async: false

  alias Candil.MCP
  alias Candil.MCP.Server
  alias Candil.MCP.Tool

  defmodule Weather do
    @behaviour Candil.MCP.Tool

    def name, do: "weather"
    def description, do: "the weather"

    def schema,
      do: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }

    def call(%{"city" => city}), do: {:ok, "sunny in #{city}"}
  end

  setup do
    Candil.Tool.reset()
    Tool.register(Weather)
    on_exit(fn -> Candil.Tool.reset() end)
    :ok
  end

  test "tools/list includes the third-party tool" do
    {:ok, server} = MCP.serve()

    response =
      Server.handle_request(server, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    names = Enum.map(response.result.tools, & &1.name)
    assert "weather" in names
    GenServer.stop(server)
  end

  test "tools/call dispatches to the third-party tool" do
    {:ok, server} = MCP.serve()

    response =
      Server.handle_request(server, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "weather", "arguments" => %{"city" => "Madrid"}}
      })

    assert [%{type: "text", text: text}] = response.result.content
    assert text =~ "sunny in Madrid"
    GenServer.stop(server)
  end

  test "a tool that raises is -32_603 and does not take the server down" do
    defmodule Boom do
      @behaviour Candil.MCP.Tool
      def name, do: "boom"
      def description, do: "boom"
      def schema, do: %{"type" => "object"}
      def call(_), do: raise("kaboom")
    end

    Tool.register(Boom)

    {:ok, server} = MCP.serve()

    response =
      Server.handle_request(server, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "boom", "arguments" => %{}}
      })

    assert response.error.code == -32_603
    assert response.error.message =~ "boom"

    # The server is still alive.
    response2 =
      Server.handle_request(server, %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/list",
        "params" => %{}
      })

    assert is_list(response2.result.tools)
    GenServer.stop(server)
  end
end
