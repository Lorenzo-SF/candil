defmodule Candil.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Candil.{Doctor, Engine, Instances, Model, Store}

  setup do
    # The Store is application state that other files also write to.
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    Enum.each(Store.list_engines(), &Store.deregister_engine(&1.alias))
    Enum.each(Store.list_providers(), &Store.deregister_provider(&1.alias))

    dir = Path.join(System.tmp_dir!(), "candil-doc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("CANDIL_DATA_DIR")
    System.put_env("CANDIL_DATA_DIR", dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: System.put_env("CANDIL_DATA_DIR", previous)
    end)

    {:ok, dir: dir}
  end

  defp write_config!(dir, contents) do
    File.mkdir_p!(Path.join(dir, "candil"))
    File.write!(Path.join([dir, "candil", "candil.toml"]), contents)
    System.put_env("CANDIL_CONFIG", Path.join([dir, "candil", "candil.toml"]))
    on_exit(fn -> System.delete_env("CANDIL_CONFIG") end)
  end

  defp engine!(attrs \\ []) do
    alias_ = Keyword.get(attrs, :alias, :e)

    # A `%Build{}` that Engine.validate/1 actually accepts. An invalid one
    # makes `Store.register_engine/1` refuse, and the test fails on the setup
    # rather than on the behaviour it is here to check.
    build =
      case Keyword.get(attrs, :install) do
        nil ->
          nil

        %Candil.Build{} = build ->
          build

        strategy ->
          %Candil.Build{
            strategy: strategy,
            repo: "https://example.test/llama.cpp",
            ref: "b1",
            dir: "/nowhere/bin",
            binaries: ["llama-server"]
          }
      end

    :ok =
      Store.register_engine(%Engine{
        alias: alias_,
        binary: Keyword.get(attrs, :binary, "/nowhere/llama-server"),
        host: "127.0.0.1",
        base_port: 19_000,
        api_key: Keyword.get(attrs, :api_key),
        install: build
      })

    alias_
  end

  defp model!(alias_name, opts \\ []) do
    # A local model needs a locatable file to be accepted by the catalogue at
    # all, so these tests point at a file that is deliberately NOT there. That
    # is the shape `sources/0` is meant to report on.
    file =
      Path.join(System.tmp_dir!(), "candil-absent-#{System.unique_integer([:positive])}.gguf")

    :ok =
      Store.register_model(%Model{
        alias: alias_name,
        type: Keyword.get(opts, :type, :local),
        engine: Keyword.get(opts, :engine, :e),
        provider: Keyword.get(opts, :provider),
        name: Keyword.get(opts, :name),
        model_dir: Keyword.get(opts, :model_dir, Path.dirname(file)),
        filename: Keyword.get(opts, :filename, Path.basename(file)),
        context_size: 4096,
        port: 9999
      })
  end

  defp check(report, name), do: Enum.find(report.checks, &(&1.name == name))

  describe "the report shape" do
    test "always has the eight checks, in the design document's order" do
      report = Doctor.run()

      assert [:config, :binary, :sources, :ports, :auth, :gpu, :memory, :disk] =
               Enum.map(report.checks, & &1.name)

      assert %{errors: errors, warnings: warnings} = report
      assert is_integer(errors) and is_integer(warnings)
    end

    test "errors and warnings are counted, not guessed" do
      report = Doctor.run()
      counted = Enum.count(report.checks, &(&1.level == :error))

      assert report.errors == counted
    end
  end

  describe "the message is the product" do
    test "a missing binary says the command that builds it" do
      engine!(install: :source)
      model!(:coder)

      %{level: :error, message: message, fix: fix} = check(Doctor.run(), :binary)

      assert message =~ "llama-server"
      assert message =~ "not built"
      assert fix =~ "candil engine install"
      assert fix =~ "source"
    end

    test "a missing model says the command that fetches it, and names it" do
      engine!()
      model!(:coder)
      model!(:analyst)

      %{level: :warning, message: message, fix: fix} = check(Doctor.run(), :sources)

      assert message =~ "coder"
      assert message =~ "analyst"
      assert fix =~ "candil models pull"
    end

    test "an unset env var names the variable AND the export" do
      System.delete_env("CANDIL_TEST_KEY")
      engine!(api_key: {:system, "CANDIL_TEST_KEY"})
      model!(:coder)

      %{level: :error, message: message, fix: fix} = check(Doctor.run(), :auth)

      assert message =~ "CANDIL_TEST_KEY"
      assert message =~ "NO esta puesta"
      assert fix =~ "export CANDIL_TEST_KEY"
    end

    test "an auth key that resolves says so instead of staying silent" do
      System.put_env("CANDIL_TEST_KEY", "sk-test")
      on_exit(fn -> System.delete_env("CANDIL_TEST_KEY") end)
      engine!(api_key: {:system, "CANDIL_TEST_KEY"})
      model!(:coder)

      assert %{level: :ok, message: message} = check(Doctor.run(), :auth)
      assert message =~ "CANDIL_TEST_KEY"
    end
  end

  describe "one check, one crash" do
    test "a check that raises does not take the report with it" do
      # The moduledoc promised this and the code did not: only memory/0 was
      # wrapped. An engine whose `binary` blew up inside
      # `Engine.binary_path/1` took all six other checks down with it — which
      # is the one machine where you most need the doctor.
      System.delete_env("CANDIL_TEST_KEY")
      engine!(alias: :e, binary: "not/a/path/but/also/not/a/struct")
      model!(:coder)

      report = Doctor.run()

      assert length(report.checks) == 8
      assert Enum.find(report.checks, &(&1.name == :binary)).level in [:error, :warning]
    end

    test "the report still renders when a check exploded" do
      report = %{
        checks: [%{name: :binary, level: :error, message: "reventó", fix: nil}],
        errors: 1,
        warnings: 0
      }

      assert render = Doctor.render(report)
      assert render =~ "reventó"
      assert render =~ "1 errores"
    end
  end

  describe "an empty or broken configuration" do
    test "no config at all is a warning, not a lie saying all is well" do
      # A doctor that says "todo bien" about a machine with no configuration
      # is worse than useless.
      System.put_env("CANDIL_CONFIG", "/nowhere/nothing.toml")
      on_exit(fn -> System.delete_env("CANDIL_CONFIG") end)

      report = Doctor.run()
      config = check(report, :config)

      assert config.level in [:warning, :error]
    end

    test "a config that does not validate names the problems" do
      write_config!(System.get_env("CANDIL_DATA_DIR"), """
      [model.coder]
      type = "inventado"
      """)

      config = check(Doctor.run(), :config)
      assert config.level == :error
      assert config.message =~ "no valida"
    end
  end

  describe "--fix" do
    test "creates the data directory when it is missing" do
      dir = Path.join(System.tmp_dir!(), "candil-fix-#{System.unique_integer([:positive])}")
      System.put_env("CANDIL_DATA_DIR", dir)
      on_exit(fn -> File.rm_rf(dir) end)

      refute File.dir?(dir)

      _report = Doctor.run(fix: true)

      assert File.dir?(dir)
    end

    test "creates the CONFIGURED log directory, not <data_dir>/logs" do
      # `general.log_dir` used to be a key the schema validated, the sample
      # TOML declared, and no code read. `--fix` wrote `<data_dir>/logs` and
      # announced that path, so the file and the behaviour disagreed and only
      # the file was believed.
      dir = Path.join(System.tmp_dir!(), "candil-logfix-#{System.unique_integer([:positive])}")
      logs = Path.join(Path.join(dir, "elsewhere"), "journal")
      write_config!(dir, ~s([general]\ndata_dir = "#{dir}"\nlog_dir = "#{logs}"\n))
      on_exit(fn -> File.rm_rf(dir) end)

      _report = Doctor.run(fix: true)

      assert File.dir?(logs), "the configured log_dir was not created"
      assert Instances.log_dir() == logs
    end

    test "the report says which directories it created" do
      # A `--fix` that repairs a path and names a different one teaches the
      # user to stop reading the report.
      dir = Path.join(System.tmp_dir!(), "candil-say-#{System.unique_integer([:positive])}")
      write_config!(dir, ~s([general]\ndata_dir = "#{dir}"\nlog_dir = "#{dir}/j"\n))
      on_exit(fn -> File.rm_rf(dir) end)

      report = Doctor.run(fix: true)

      assert check(report, :config).message =~ dir
      assert check(report, :config).message =~ Path.join(dir, "j")
    end

    test "lists what it could NOT fix, with the command" do
      # A `--fix` that swallows a failure is worse than no `--fix`: the user
      # believes it was repaired.
      engine!(install: :source)
      model!(:coder)

      pending = Doctor.run(fix: true).checks |> Enum.reject(&is_nil(&1.fix))

      assert pending != []
      assert Enum.all?(pending, &(&1.fix =~ "candil "))
    end
  end

  describe "disk comes from botica too" do
    test "the message is botica's, not one we made up" do
      disk = check(Doctor.run(), :disk)

      assert is_binary(disk.message)
      assert disk.message != ""
    end
  end

  describe "memory comes from botica" do
    test "the report has botica's own words, not a number we made up" do
      # If this ever says something empty, the shape of botica's answer
      # changed and `memory/0` is silently lying with a green tick.
      memory = check(Doctor.run(), :memory)
      assert is_binary(memory.message)
      assert memory.message != ""
    end
  end

  describe "--json" do
    test "es una LISTA, no un objeto, y por eso se puede pasar por jq" do
      # El criterio de la CLI entera es `jq '.[0].model'`. Un objeto
      # obligaría a `.checks[0].model` y el criterio es una sugerencia.
      out = capture_io(fn -> Candil.CLI.Doctor.run(%{json: true}) end)
      decoded = Jason.decode!(out)

      assert is_list(decoded)
      assert is_map(hd(decoded))
      assert %{"name" => _, "level" => _, "message" => _, "fix" => _} = hd(decoded)
    end
  end

  describe "render/1" do
    test "one line per check, and a total" do
      report = Doctor.run()
      rendered = Doctor.render(report)

      for name <- [:config, :binary, :sources, :ports, :auth, :gpu, :memory] do
        assert rendered =~ to_string(name)
      end

      assert rendered =~ "#{report.errors} errores"
      assert rendered =~ "#{report.warnings} advertencias"
    end
  end
end
