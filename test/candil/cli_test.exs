defmodule Candil.CLITest do
  # async: false because the setup drains the shared Store, and another file
  # populating it concurrently makes these tests order-dependent.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Candil.CLI
  alias Candil.CLI.{Colorize, Escript, Help, Holder, Lifecycle, Ports, Preflight}
  alias Candil.{Engine, EnginePool, Instances, Model, Store}

  doctest Candil.CLI.Version

  setup do
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    Enum.each(Store.list_engines(), &Store.deregister_engine(&1.alias))
    Enum.each(Store.list_providers(), &Store.deregister_provider(&1.alias))
    # The EnginePool is shared too. `Engine.stop/1` now clears it, but a file
    # that dies mid-test can still leave an instance behind, and `status` would
    # then print a row where this test expects an empty registry.
    Enum.each(EnginePool.list(), &EnginePool.delete(&1.alias, &1.port))
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

  describe "the exit status" do
    # An escript's exit status is its `main/1` return, and only if that is an
    # integer. Handlers return atoms, so without a translation at the boundary
    # `candil doctor` on a machine with no engine binary printed a report full
    # of failures and exited 0 — and a CI pipeline went green on it.
    test "an :error from a handler becomes 1" do
      assert Escript.exit_status(:error) == 1
      assert Escript.exit_status({:error, :circuit_open}) == 1
    end

    test ":ok and anything unrecognised stay 0" do
      assert Escript.exit_status(:ok) == 0
      assert Escript.exit_status(nil) == 0
      assert Escript.exit_status([]) == 0
    end

    test "an integer passes through, so a framework usage error is not lost" do
      assert Escript.exit_status(2) == 2
    end
  end

  describe "dispatch" do
    test "the bare word `version` prints the version" do
      # Not just the flag. The first cut only knew `--version` and `-v`, so
      # the spelling a person actually types fell through to the help and
      # looked like a broken binary.
      assert capture_io(fn -> CLI.main(["version"]) end) =~ "Candil "
    end

    # `Escript.expand/1` and `CLI.main/1`, separately — never
    # `Escript.main/1`. That one ends in `System.halt/1` on purpose, so calling
    # it from a test kills the run part-way through and `mix test` still exits
    # **0**: a suite that looks green because it stopped. It cost one round of
    # "34 dots and no summary" to find that out.
    #
    # The two halves are what is under test anyway: `expand/1` owns the alias
    # table and `CLI.main/1` owns the dispatch. Going through `Escript.main/1`
    # would also have tested a path where `--version` and `version` are
    # different entries — Alaja owns `--version` as a global option and prints
    # its own, lowercase — and "fixing" that disagreement would have hidden the
    # fact that they never were the same entry.
    test "the flag spellings agree with it" do
      dispatch = fn argv -> capture_io(fn -> argv |> Escript.expand() |> CLI.main() end) end

      expected = dispatch.(["version"])

      for spelling <- ["--version", "-v"] do
        assert dispatch.([spelling]) == expected
      end
    end

    test "the alias table rewrites the first token only" do
      # `candil models remove --version` means a model called `--version`, not
      # a request for the version.
      assert Escript.expand(["--version"]) == ["version"]
      assert Escript.expand(["models", "--version"]) == ["models", "--version"]
      assert Escript.expand([]) == []
    end

    test "an unknown command returns :error, which is what makes the exit 1" do
      # `catch_all` routes it here. Returning `:ok` instead would print a good
      # error and exit 0, which is the bug this replaced.
      # stderr, not stdout: a failure that says so on stdout lands in whatever
      # a script was capturing.
      err = capture_io(:stderr, fn -> assert :error = Escript.unknown(%{name: "frobnicate"}) end)
      assert err =~ "frobnicate"
    end

    test "unknown input prints the usage rather than raising" do
      assert capture_io(fn -> CLI.main([]) end) =~ "Command"

      # On stderr, and in Alaja's words. The assertion that matters is the one
      # that was always missing: no stack trace, and the bad token named. The
      # exact phrasing belongs to the framework now, so pinning it here would
      # be a test that fails on an upgrade for no good reason.
      error = capture_io(:stderr, fn -> CLI.main(["frobnicate"]) end)

      refute error =~ "** (", "an unknown command must not raise"
      assert error =~ "frobnicate"
    end

    test "the lifecycle verbs are routed, not treated as models" do
      assert capture_io(fn -> CLI.main(["status"]) end) =~ "instancias"
      assert capture_io(fn -> CLI.main(["models", "list"]) end) =~ "no models"
    end

    # The next two are here because the binary shipped broken with 702 tests
    # green: nobody ran it, and the CI did not build it either.
    test "the help lists every command the dispatch table can reach" do
      shown = Help.top_level_commands() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      dispatchable = CLI.command_names() |> MapSet.new()

      assert dispatchable == shown,
             "these are dispatchable but missing from the help: " <>
               inspect(MapSet.difference(dispatchable, shown))
    end

    # The description now lives in the declaration, next to the flag it
    # describes, so that is where the invariant is checked. Asserting it
    # against a hand-rolled help string would be asserting that a copy of the
    # declaration is a copy of the declaration.
    test "every declared command has a description, not a blank line" do
      for command <- CLI.__commands__() do
        assert command.description != "", "#{command.name} is declared with no description"
      end
    end

    # No in-process test for this one, and that is deliberate: the DSL answers
    # a usage error with `System.halt(1)`, which is the right thing for a binary
    # and impossible to assert from inside the VM — the test run dies with it.
    # The contract is checked where it is actually observable, in the CI smoke
    # step, which runs the built escript: "candil run with no model exits
    # non-zero, names the command and the missing argument, and prints no stack
    # trace". A test that had to be deleted to keep the suite alive is a test
    # that was in the wrong place.
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

      out = capture_io(fn -> Lifecycle.run_model(%{model: "analyst", port: 9999}) end)
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

      capture_io(fn -> Lifecycle.run_model(%{model: "analyst", port: 9999}) end)

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

      out = capture_io(fn -> Lifecycle.status(%{json: true}) end)
      [row] = Jason.decode!(out)
      assert row["model"] == "coder"
      assert row["port"] == 9999
      # There IS a row, and nothing is serving on that port. "ON" here used
      # to mean "there is a row", which sent the user to debug the wrong
      # thing. The honest answer with a row and no server is DOWN.
      assert row["state"] == "DOWN"
    end

    test "with nothing running it says so" do
      assert capture_io(fn -> Lifecycle.status(%{}) end) =~ "no hay instancias"
    end
  end

  describe "the colouriser" do
    test "an error is red and throughput is magenta" do
      assert Colorize.level_for("CUDA error: no kernel image") == :error
      assert Colorize.level_for("eval time: 12.3 ms/token") == :magenta
    end

    test "a loaded model is green" do
      assert Colorize.level_for("main: server is listening on http://0.0.0.0:8080") == :success
    end

    test "an OOM is red, which is the line that matters" do
      assert Colorize.level_for("ggml: out of memory") == :error
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

  describe "run --detach (fase 4)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "candil-f4-#{System.unique_integer([:positive])}")
      previous = System.get_env("CANDIL_DATA_DIR")
      System.put_env("CANDIL_DATA_DIR", dir)

      on_exit(fn ->
        File.rm_rf(dir)
        if previous, do: System.put_env("CANDIL_DATA_DIR", previous)
      end)

      :ok
    end

    # Este test afirmaba, en un comentario, que el dueño era "el pid de este
    # proceso, porque es lo que cuya muerte se lleva el engine detras". Eso es
    # exactamente el bug: el pid escrito era el del escript que salia acto
    # seguido, `alive?/1` lo poda, y el engine se iba con el. Comprobado con
    # un escript de verdad: /proc/<pid> muerto, sin proceso, log que no existia
    # y un registro con healthy: true.
    test "no deja un registro si no hay nadie a quien pertenezca" do
      model!(:coder)
      engine!()

      out =
        capture_io(fn ->
          Lifecycle.run_model(%{model: "coder", port: 10_500, detach: true})
        end)

      # Sin escript delante no hay titular que lanzar, y un registro sin dueno
      # es un corpse esperando: no se escribe, y no se dice que ha arrancado.
      assert Instances.read() == []
      refute out =~ "detached"
    end

    # Este es el bug que el usuario vio en su maquina: el titular se quedaba
    # vivo con su claim escrito, el engine no habia llegado a responder, y
    # `status` decia detached y luego DOWN — con la GPU a 47 MB y el puerto
    # libre. Aqui no hay engine, y por eso la puerta TIENE que estar cerrada.
    test "el titular NO reclama un puerto si el engine no llega a responder" do
      model!(:coder)
      engine!()

      task = Task.async(fn -> Holder.start("coder", 10_500) end)
      assert {:error, reason} = Task.await(task, 30_000)
      assert reason in [:timeout, :engine_died]

      # Sin claim, `status` no inventa nada y `stop` no tiene a quien parar.
      assert Instances.read() == []
    end

    test "el motivo de fallo se explica en castellano, no en atomos" do
      assert Holder.explain(:timeout) =~ "no ha contestado"
      assert Holder.explain(:engine_died) =~ "se ha caido"
      assert Holder.explain(:no_such_model) =~ "no hay ningun modelo"
    end

    # La tabla y el `--json` son dos renderizadores de las mismas filas, y con
    # los tests cubriendo solo el json, `row/1` llego a pedir `:started_at` a una
    # fila que ya lleva `:uptime_ms` y revento con KeyError en `candil status`,
    # justo en el camino que se ejecuta sin querer. Ningun test lo vio porque
    # ninguno miraba la tabla.
    test "status sin --json sabe pintar una instancia que solo esta en el registro" do
      dir = Path.join(System.tmp_dir!(), "candil-detached-#{System.unique_integer([:positive])}")
      previous = System.get_env("CANDIL_DATA_DIR")
      System.put_env("CANDIL_DATA_DIR", dir)
      on_exit(fn -> if previous, do: System.put_env("CANDIL_DATA_DIR", previous) end)

      # Sin motor local: si lo hubiera, `running/0` lo pondria delante por
      # `{model, port}` y no se veria la fila remota en absoluto. Que la local
      # gane tambien es lo correcto, asi que esto no es un rodeo: es como se
      # ve de verdad una instancia detached, que esta en otro proceso.
      instance =
        Instances.build("coder", 10_600, "llama_cpp", Instances.os_pid(), true)

      :ok = Instances.put({"coder", 10_600}, instance)

      out = capture_io(fn -> Lifecycle.status(%{json: false}) end)

      assert out =~ "coder"
      assert out =~ "detached"
      assert out =~ "10600"
      # Y DOWN, no ON. El dueno de este registro esta vivo —es el propio test—
      # pero no hay nadie escuchando en el puerto, que es lo que decia la
      # columna. Antes salia ON porque el registro traia un `healthy: true`
      # del momento del arranque y nunca se volvia a mirar. Un proceso vivo
      # que no sirve ocupa GPU y ocupa puerto: tiene que verse como DOWN.
      assert out =~ "DOWN"
    end

    test "an explicit --port is remembered for the next run" do
      model!(:coder)
      engine!()

      # En el camino de foreground, que es donde se registra. El de detach lo
      # hace el titular, en otro proceso, y un test unitario no puede observar
      # eso sin lanzar un escript entero.
      capture_io(fn -> Lifecycle.run_model(%{model: "coder", port: 10_500, detach: false}) end)

      assert 10_500 in Instances.ad_hoc_ports()
    end
  end

  describe "stop (fase 4)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "candil-f4b-#{System.unique_integer([:positive])}")
      previous = System.get_env("CANDIL_DATA_DIR")
      System.put_env("CANDIL_DATA_DIR", dir)

      on_exit(fn ->
        File.rm_rf(dir)
        if previous, do: System.put_env("CANDIL_DATA_DIR", previous)
      end)

      :ok
    end

    test "stops an instance that lives in ANOTHER process" do
      # The case that only exists because of instances.json: a detached engine
      # is absent from this VM's pool by construction, and stopping only what
      # is in memory reports "nothing running" about something running.
      # A real second process, so "is it alive" has a real answer.
      {out, 0} = System.cmd("sh", ["-c", "sleep 30 & echo $!"], stderr_to_stdout: true)
      owner = out |> String.trim() |> String.to_integer()

      instance = Instances.build("coder", 9999, "llama_cpp", owner, true)
      :ok = Instances.put({"coder", 9999}, instance)

      capture_io(fn -> Lifecycle.stop(%{model: "coder"}) end)

      refute Instances.alive?(%{pid: owner}), "the owner was signalled but is still alive"
      assert [] == Instances.read(), "the entry was not removed from instances.json"
    end

    test "says so when there is nothing to stop" do
      out = capture_io(fn -> Lifecycle.stop(%{model: "nada"}) end)
      assert out =~ "no hay instancias"
    end
  end

  describe "status (fase 4)" do
    test "STATE comes from the health poller, not from having a row" do
      EnginePool.put(
        :coder,
        9999,
        self(),
        %Model{alias: :coder, type: :local, engine: :e},
        %Engine{alias: :e}
      )

      on_exit(fn -> EnginePool.delete(:coder, 9999) end)

      out = capture_io(fn -> Lifecycle.status(%{json: true}) end)
      [row] = Jason.decode!(out)

      # There is a row, but nothing is serving on that port, so the honest
      # answer is DOWN. A table that says ON here sends the user to debug the
      # wrong thing.
      assert row["state"] == "DOWN"
    end
  end

  defp os_pid do
    case System.pid() do
      pid when is_integer(pid) -> pid
      pid when is_binary(pid) -> String.to_integer(pid)
      pid when is_list(pid) -> List.to_integer(pid)
    end
  end

  # Un proceso que arranca un engine y luego se queda esperando no avisa
  # cuando ha terminado de hacerlo. Esperar a la condicion es lo unico que no
  # convierte un test en una loteria con el ancho de banda de la maquina.
  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("la condicion no se cumplio en 100 intentos")
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end
end
