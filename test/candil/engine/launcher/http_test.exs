defmodule Candil.Engine.Launcher.HttpTest do
  use ExUnit.Case, async: true

  alias Candil.Engine
  alias Candil.Engine.Launcher.Http
  alias Candil.Model

  defp engine(opts \\ []) do
    %Engine{
      alias: :tgi,
      host: Keyword.get(opts, :host, "10.0.0.5"),
      port: Keyword.get(opts, :port, 8080),
      launcher: Http
    }
  end

  defp model, do: %Model{alias: :tgi, type: :remote, provider: :openai, name: "tgi"}

  describe "launch/2" do
    test "returns the engine's own base URL" do
      assert {:ok, %{base_url: "http://10.0.0.5:8080"}} = Http.launch(engine(), model())
    end

    test "works on loopback and on a remote host alike" do
      # Same code, and it has to: the difference between LM Studio on this
      # machine and vLLM on another box is an address, not a lifecycle.
      local = %Engine{alias: :lms, host: "127.0.0.1", port: 1234, launcher: Http}
      assert {:ok, %{base_url: "http://127.0.0.1:1234"}} = Http.launch(local, model())
    end

    test "always answers pid: nil, because the process is not ours" do
      # The safety property of this module. A launcher that returned a pid it
      # did not start would make `candil stop` kill a shared service that
      # other people were using.
      assert {:ok, %{pid: nil}} = Http.launch(engine(), model())
      refute Http.owns_process?()
    end

    test "it is a Candil.Engine.Launcher, so Engine.start/2 accepts it" do
      # The behaviour is what wires it in; without it the engine would be
      # started as if it were a local llama-server.
      # `function_exported?/3` answers false for a module that is not loaded
      # yet, which makes this test a question about load order rather than
      # about the launcher. `Code.ensure_loaded/1` first.
      assert {:module, Http} = Code.ensure_loaded(Http)
      assert function_exported?(Http, :launch, 2)
      assert Engine.Launcher in (Http.module_info(:attributes)[:behaviour] || [])
    end
  end
end
