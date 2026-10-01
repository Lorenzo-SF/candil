defmodule Candil.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Candil.MCP
  alias Candil.MCP.Protocol

  doctest Candil.MCP.Protocol

  describe "the revision, and why it is not 2024-11-05" do
    test "is 2025-11-25" do
      assert Protocol.version() == "2025-11-25"
      assert MCP.version() == "2025-11-25"
    end

    test "2024-11-05 is served only as a fallback, never announced" do
      assert "2024-11-05" in Protocol.supported()
      refute Protocol.version() == "2024-11-05"
    end

    test "supported?/1 is an exact match on a string" do
      assert Protocol.supported?("2025-11-25")
      refute Protocol.supported?("2025-11-25 ")
      refute Protocol.supported?(:latest)
    end
  end

  describe "negotiate/1" do
    test "echoes a revision we support" do
      assert Protocol.negotiate("2025-11-25") == {:ok, "2025-11-25"}
      assert Protocol.negotiate("2024-11-05") == {:ok, "2024-11-05"}
    end

    test "a missing version is assumed to be 2025-03-26" do
      # That is what the specification says to assume, and assuming anything
      # else means silently disagreeing with the client about the protocol.
      assert Protocol.negotiate(nil) == {:ok, "2025-03-26"}
      assert Protocol.default_http_version() == "2025-03-26"
    end

    test "an unknown revision is an error, not a silent downgrade" do
      # A client moved to a revision it did not ask for fails in ways that
      # look like server bugs.
      assert Protocol.negotiate("1999-01-01") == {:error, :unsupported_version}
    end
  end

  describe "check_http_header/1" do
    test "no header proceeds, on the assumed revision" do
      assert {:ok, "2025-03-26"} = Protocol.check_http_header(nil)
    end

    test "a good header proceeds on that revision" do
      assert {:ok, "2025-06-18"} = Protocol.check_http_header("2025-06-18")
    end

    test "a bad header is a 400 that says what is supported" do
      assert {:error, {:bad_request, message}} = Protocol.check_http_header("9999-99-99")
      assert message =~ "9999-99-99"
      assert message =~ "2025-11-25"
    end
  end

  describe "batching, removed in 2025-06-18" do
    test "an array is recognised as a batch" do
      assert Protocol.batch?([%{id: 1}, %{id: 2}])
      refute Protocol.batch?(%{id: 1})
    end

    test "a batch gets -32600 and an explanation" do
      error = Protocol.batch_error()
      assert error.error.code == -32_600
      assert error.error.message =~ "batching was removed"
    end

    test "an empty array is still a batch" do
      # It is an array. Whether it is empty does not change what it is.
      assert Protocol.batch?([])
    end
  end

  describe "initialize" do
    test "announces our revision and what we can do" do
      result = Protocol.initialize_result()

      assert result.jsonrpc == "2.0"
      assert result.result.protocolVersion == "2025-11-25"
      assert result.result.capabilities.tools == %{}
      assert result.result.serverInfo.name == "candil"
    end
  end

  describe "methods" do
    test "initialize is first, because the handshake is not optional" do
      assert "initialize" == List.first(Protocol.server_methods())
    end

    test "tools and resources are both there" do
      methods = Protocol.server_methods()
      assert "tools/list" in methods
      assert "tools/call" in methods
      assert "resources/list" in methods
    end

    test "the header is the one the specification names" do
      assert Protocol.version_header() == "MCP-Protocol-Version"
    end
  end

  describe "Candil.MCP" do
    test "transports are stdio first" do
      # stdio is how a host launches a server, and it has no port to collide
      # with and nothing listening afterwards.
      assert MCP.transports() == [:stdio, :http]
    end

    test "tools/list entry renames schema to inputSchema" do
      assert MCP.tool_wire(%{name: "w", description: "d", schema: %{"type" => "object"}}) ==
               %{name: "w", description: "d", inputSchema: %{"type" => "object"}}
    end

    test "a tool result is a list of typed blocks, not a bare string" do
      assert MCP.call_result("hola") == %{content: [%{type: "text", text: "hola"}]}
    end

    test "a non-string result is rendered rather than dropped" do
      assert %{content: [%{text: text}]} = MCP.call_result(%{temp: 20})
      assert text =~ "temp"
    end

    test "a tool that raised is -32603 and names the tool" do
      error = MCP.tool_error(%RuntimeError{message: "boom"}, :weather)
      assert error.error.code == -32_603
      assert error.error.message =~ "weather"
      assert error.error.message =~ "boom"
    end

    test "serve and connect are honest about being phase 9" do
      assert {:error, %Candil.Error{reason: :not_implemented}} = MCP.serve()
      assert {:error, %Candil.Error{reason: :not_implemented}} = MCP.connect()
    end
  end
end
