defmodule Candil.Instances.ProbeTest do
  @moduledoc """
  Is anyone really listening, or just a process that answers nothing.

  The defect that motivated this module: `status` said `ON` with `sleep 9999`
  standing in for the engine, because the registry kept a `healthy: true` from
  the moment it started and never looked again. A user spotted it with a tool
  that is not Candil, which reported the port free while `candil status`
  reported the model serving.
  """
  use ExUnit.Case, async: true

  alias Candil.Instances.Probe

  describe "listening?/3" do
    test "says yes when something is listening" do
      {socket, port} = listen!()
      assert Probe.listening?("127.0.0.1", port)
      :gen_tcp.close(socket)
    end

    test "says no when nothing is there" do
      refute Probe.listening?("127.0.0.1", closed_port())
    end

    test "a port above 65535 does not take status down" do
      # A system call error must not escape into `status`: a garbage registry
      # entry reports DOWN, it does not crash the command.
      refute Probe.listening?("127.0.0.1", 65_536)
    end

    test "an invalid host does not take status down" do
      refute Probe.listening?("no-es-un-host", 9_999)
    end
  end

  describe "states/2" do
    test "asks every port and answers one state per port" do
      {socket, live} = listen!()
      dead = closed_port()

      rows = Enum.map([live, dead], &%{port: &1, host: "127.0.0.1"})

      assert %{^live => "ON"} = Probe.states(rows)
      assert %{^live => "ON", ^dead => "DOWN"} = Probe.states(rows)

      :gen_tcp.close(socket)
    end

    test "an empty list breaks nothing" do
      assert Probe.states([]) == %{}
    end
  end

  defp listen! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  # Opened and immediately closed: free with near-certainty.
  defp closed_port do
    {socket, port} = listen!()
    :gen_tcp.close(socket)
    port
  end
end
