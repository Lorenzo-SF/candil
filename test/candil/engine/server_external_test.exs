defmodule Candil.Engine.Server.ExternalTest do
  use ExUnit.Case, async: false

  alias Candil.Engine
  alias Candil.Engine.Server.External

  @base_url "http://127.0.0.1:65535"

  defp fixture_engine do
    %Engine{alias: :ext_test, host: "127.0.0.1", port: 65_535}
  end

  defp fixture_model do
    %Candil.Model{
      alias: :ext_test_model,
      type: :local,
      model_dir: "/models",
      filename: "ext.gguf"
    }
  end

  describe "init/1" do
    test "returns ok with correct state and pid: nil" do
      engine = fixture_engine()
      model = fixture_model()
      args = %{base_url: @base_url, pid: nil, engine: engine, model: model}

      assert {:ok, state} = External.init(args)
      assert state.base_url == @base_url
      assert state.engine == engine
      assert state.model == model
      assert state.pid == nil
      assert state.healthy == false
    end

    test "returns ok with correct state and external pid" do
      external = spawn(fn -> Process.sleep(:infinity) end)
      engine = fixture_engine()
      model = fixture_model()
      args = %{base_url: @base_url, pid: external, engine: engine, model: model}

      assert {:ok, state} = External.init(args)
      assert state.pid == external

      Process.exit(external, :kill)
    end
  end

  describe "handle_call/3" do
    test ":base_url returns base_url" do
      state = %{
        engine: fixture_engine(),
        model: fixture_model(),
        base_url: @base_url,
        pid: nil,
        healthy: false
      }

      assert {:reply, @base_url, ^state} = External.handle_call(:base_url, {self(), :ref}, state)
    end

    test ":health returns :ok when healthy" do
      state = %{
        engine: fixture_engine(),
        model: fixture_model(),
        base_url: @base_url,
        pid: nil,
        healthy: true
      }

      assert {:reply, :ok, ^state} = External.handle_call(:health, {self(), :ref}, state)
    end

    test ":health returns :not_ready when not healthy" do
      state = %{
        engine: fixture_engine(),
        model: fixture_model(),
        base_url: @base_url,
        pid: nil,
        healthy: false
      }

      assert {:reply, :not_ready, ^state} = External.handle_call(:health, {self(), :ref}, state)
    end
  end

  describe "terminate/2" do
    test "with pid: nil is a noop" do
      state = %{
        engine: fixture_engine(),
        model: fixture_model(),
        base_url: @base_url,
        pid: nil,
        healthy: false
      }

      assert :ok = External.terminate(:normal, state)
    end

    test "with pid: sends :shutdown to the external process" do
      test_pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:EXIT, _from, :shutdown} -> :got_shutdown
          after
            1_000 -> :timeout
          end
        end)

      state = %{
        engine: fixture_engine(),
        model: fixture_model(),
        base_url: @base_url,
        pid: test_pid,
        healthy: false
      }

      ref = Process.monitor(test_pid)
      assert :ok = External.terminate(:normal, state)

      assert_receive {:DOWN, ^ref, :process, ^test_pid, _reason}, 1_000
    end
  end

  describe "as a GenServer" do
    test "registers in Candil.Registry under the model alias" do
      model = fixture_model()
      engine = fixture_engine()

      {:ok, pid} =
        External.start_link(%{
          base_url: @base_url,
          pid: nil,
          engine: engine,
          model: model
        })

      assert [{^pid, _}] = Registry.lookup(Candil.Registry, model.alias)

      assert GenServer.call(pid, :base_url) == @base_url
      assert GenServer.call(pid, :health) == :not_ready

      GenServer.stop(pid, :normal)
    end
  end
end
