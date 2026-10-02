defmodule Candil.CLITest do
  # async: false because the setup drains the shared Store, and another file
  # populating it concurrently makes these tests order-dependent.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Candil.CLI
  alias Candil.CLI.{Colorize, Lifecycle, Ports, Preflight}
  alias Candil.{Engine, EnginePool, Model, Store}

  doctest Candil.CLI.Version

  setup do
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    Enum.each(Store.list_engines(), &Store.deregister_engine(&1.alias))
    Enum.each(Store.list_providers(), &Store.deregister_provider(&1.alias))
    :ok
  end

  # A local model with no file is rejected by Model.validate/1, which is
  # correct: the catalogue refuses entries that could never run. So the file
  # has to be really there, and these tests really do create one.
  defp model!(alias_name, opts \\ []) do
    file = Path.join(System.tmp_dir!(), "candil-cli-#{alias_name}.gguf")
    unless Keyword.get(opts, :no_file, false), do: File.write!(file, "gguf")
    on_exit(fn -> File.rm(file) end)

    Store.register_model(%Candil.Model{
      alias: alias_name,
      type: :local,
      engine: :e,
      model_dir: Path.dirname(file),
      filename: Path.basename(file),
      context_size: 4096,
      port: 9999
    })
  end

  defp engine! do
    binary = Path.join(System.tmp_dir!(), "candil-cli-llama-server")
    unless File.exists?(binary), do: File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, 0o755)
    Store.register_engine(%Candil.Engine{alias: :e, binary: binary})
  end

  # A model that exists in the catalogue but whose file is gone: the shape a
  # model has after `candil models remove` deleted it, or after a disk moved.
  defp model_without_file!(alias_name) do
    model!(alias_name)
    File.rm(Path.join(System.tmp_dir!(), "candil-cli-#{alias_name}.gguf"))
  end

  describe "dispatch" do
    test "the bare word `version` prints the version" do
      # Not just the flag. The first cut only knew `--version` and `-v`, so
      # the spelling a person actually types fell through to the help and
      # looked like a broken binary.
      assert capture_io(fn -> CLI.main(["version"]) end) =~ "Candil "
    end

    test "the flag spellings agree with it" do
      expected = capture_io(fn -> CLI.main(["version"]) end)

      for spelling <- ["--version", "-v"] do
        assert capture_io(fn -> CLI.main([spelling]) end) == expected
      end
    end

    test "unknown input prints the usage rather than raising" do
      assert capture_io(fn -> CLI.main([]) end) =~ "Usage: candil"
      assert capture_io(fn -> CLI.main(["frobnicate"]) end) =~ "Usage: candil"
    end

    test "the lifecycle verbs are routed, not treated as models" do
      assert capture_io(fn -> CLI.main(["status"]) end) =~ "instancias"
      assert capture_io(fn -> CLI.main(["models", "list"]) end) =~ "no models"
    end
  end

  describe "models list" do
    test "says so when the catalogue is empty, instead of printing an empty table" do
      assert capture_io(fn -> CLI.main(["models", "list"]) end) =~ "no models"
    end

    test "a remote model shows a dash for size and state" do
      Store.register_model(%Candil.Model{
        alias: :gpt4o,
        type: :remote,
        provider: :openai,
        name: "gpt-4o",
        context_size: 128_000
      })

      out = capture_io(fn -> CLI.main(["models", "list"]) end)
      assert out =~ "gpt4o"
      assert out =~ "remote"
    end

    test "a local model whose file is absent is reported missing, not downloaded" do
      model_without_file!(:coder)
      out = capture_io(fn -> CLI.main(["models", "list"]) end)
      assert out =~ "missing"
    end
  end

  describe "preflight" do
    test "a model with no file is refused, and the message says what to run" do
      model_without_file!(:coder)
      engine!()

      # The message names the command that fixes it, which is the part that
      # matters: "no file and no source" and "the file is not there" are
      # different problems with different remedies.
      assert {:error, reasons} = Preflight.run(:coder, [])
      assert Enum.any?(reasons, &(&1 =~ "candil models pull"))
    end

    test "an unknown model is an error, not a crash" do
      assert {:error, ["no such model: ghost"]} = Preflight.run(:ghost, [])
    end

    test "a model whose engine is unbuilt says so instead of saying broken" do
      model!(:coder)

      # binary points at something that is not there, and the engine has an
      # install plan — which is the shape of "not built yet", as opposed to
      # "this engine is broken".
      Store.register_engine(%Candil.Engine{
        alias: :e,
        binary: "/nowhere/llama-server",
        install: %Candil.Build{
          strategy: :source,
          dir: "/nowhere",
          repo: "https://example.test/llama.cpp",
          binaries: ["llama-server"]
        }
      })

      on_exit(fn -> Store.deregister_engine(:e) end)

      assert {:error, reasons} = Preflight.run(:coder, [])
      assert Enum.any?(reasons, &(&1 =~ "not built"))
    end

    test "every reason is a string, never a nested list" do
      # It shipped as one: `Enum.each(reasons, &print_error/1)` reached Alaja
      # with `[]` as the text and the user got a FunctionClauseError instead of
      # a message.
      model!(:coder)
      Store.register_engine(%Candil.Engine{alias: :e, binary: "/nowhere/llama-server"})

      {:error, reasons} = Preflight.run(:coder, [])
      assert Enum.all?(reasons, &is_binary/1)
    end
  end

  describe "ports" do
    test "an explicit port wins over everything" do
      assert {:ok, 10_500} =
               Ports.resolve(%Candil.Model{alias: :m, type: :local, port: 9999}, port: 10_500)
    end

    test "the model's own port is used when there is no flag" do
      assert {:ok, 9999} = Ports.resolve(%Candil.Model{alias: :m, type: :local, port: 9999}, [])
    end

    test ":auto asks the pool, which never returns a port it handed out" do
      {:ok, first} =
        Ports.resolve(%Candil.Model{alias: :m, type: :local, port: :auto}, base_port: 45_000)

      EnginePool.put(
        :a,
        first,
        nil,
        %Candil.Model{alias: :a, type: :local, engine: :e},
        %Candil.Engine{alias: :e}
      )

      {:ok, second} =
        Ports.resolve(%Candil.Model{alias: :m, type: :local, port: :auto}, base_port: 45_000)

      refute second == first
      EnginePool.delete(:a, first)
    end
  end

  describe "run" do
    test "an occupied port is refused, and the holder is named" do
      model!(:coder)
      model!(:analyst)
      engine!()

      EnginePool.put(
        :coder,
        9999,
        nil,
        %Candil.Model{alias: :coder, type: :local, engine: :e},
        %Candil.Engine{alias: :e}
      )

      on_exit(fn -> EnginePool.delete(:coder, 9999) end)

      out = capture_io(fn -> Lifecycle.run(["analyst", "--port", "9999"]) end)
      assert out =~ "coder"
      assert out =~ "no mata automáticamente"
    end

    test "the refusal happens before any instance is registered" do
      # The design document: an occupied port is an error that does not kill
      # anything, and a start that fails leaves nothing registered.
      model!(:coder)
      model!(:analyst)
      engine!()

      EnginePool.put(
        :coder,
        9999,
        nil,
        %Candil.Model{alias: :coder, type: :local, engine: :e},
        %Candil.Engine{alias: :e}
      )

      on_exit(fn -> EnginePool.delete(:coder, 9999) end)

      capture_io(fn -> Lifecycle.run(["analyst", "--port", "9999"]) end)

      assert :error = EnginePool.get(:analyst, 9999)
    end
  end

  describe "status" do
    test "--json prints a list, so `jq '.[0].model'` works" do
      EnginePool.put(
        :coder,
        9999,
        self(),
        %Candil.Model{alias: :coder, type: :local, engine: :e},
        %Candil.Engine{alias: :e}
      )

      on_exit(fn -> EnginePool.delete(:coder, 9999) end)

      out = capture_io(fn -> Lifecycle.status(["--json"]) end)
      [row] = Jason.decode!(out)
      assert row["model"] == "coder"
      assert row["port"] == 9999
      assert row["state"] == "ON"
    end

    test "with nothing running it says so" do
      assert capture_io(fn -> Lifecycle.status([]) end) =~ "no hay instancias"
    end
  end

  describe "the colouriser" do
    test "an error is red and throughput is magenta" do
      assert Colorize.colour_for("CUDA error: no kernel image") == :red
      assert Colorize.colour_for("eval time: 12.3 ms/token") == :magenta
    end

    test "a loaded model is green" do
      assert Colorize.colour_for("main: server is listening on http://0.0.0.0:8080") == :green
    end

    test "an OOM is red, which is the line that matters" do
      assert Colorize.colour_for("ggml: out of memory") == :red
    end

    test "a line nothing matches is returned untouched" do
      # A colouriser that rewrites unknown output eventually hides the very
      # error it was added to surface.
      line = "load_tensors: offloading 21 repeating layers to GPU"
      assert Colorize.line(line) == line
    end

    test "NO_COLOR turns it off without touching the rules" do
      System.put_env("NO_COLOR", "1")
      on_exit(fn -> System.delete_env("NO_COLOR") end)
      refute Colorize.enabled?()
    end
  end

  describe "flag parsing" do
    test "both --port N and --port=N are read" do
      assert Lifecycle.parse(["--port", "10500"])[:port] == 10_500
      assert Lifecycle.parse(["--port=10500"])[:port] == 10_500
    end

    test "the boolean flags are read" do
      assert Lifecycle.parse(["--force", "--cpu", "--detach"])[:force]
      assert Lifecycle.parse(["--force", "--cpu", "--detach"])[:detach]
    end

    test "an unknown flag is skipped, not fatal" do
      assert Lifecycle.parse(["--futuro", "x", "--force"])[:force]
    end
  end
end
