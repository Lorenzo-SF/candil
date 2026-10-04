defmodule Candil.BuildTest do
  use ExUnit.Case, async: true

  alias Candil.Build

  doctest Candil.Build

  @precompiled %Build{strategy: :precompiled, dir: "/opt/llm"}

  @source %Build{
    strategy: :source,
    repo: "https://github.com/ggml-org/llama.cpp",
    ref: "b4561",
    src_dir: "/src/llama.cpp",
    build_dir: "/build/llama.cpp",
    generator: :ninja,
    dir: "/opt/llm",
    binaries: ["llama-server", "llama-cli"],
    cmake_args: [
      "-DCMAKE_BUILD_TYPE=Release",
      "-DCMAKE_CUDA_ARCHITECTURES=120a",
      "-DGGML_CUDA_MMQ_MXFP4=ON"
    ]
  }

  describe "new/1" do
    test "builds a valid precompiled plan" do
      assert {:ok, %Build{strategy: :precompiled}} = Build.new(strategy: :precompiled, dir: "/o")
    end

    test "a source plan needs a repo, a dir and the binaries it expects" do
      assert {:error, errors} = Build.new(strategy: :source)
      assert "repo is required" in errors
      assert "dir is required" in errors
      assert "binaries is required" in errors
    end

    test "rejects an unknown strategy" do
      assert {:error, ["strategy must be :precompiled, :source or :none, got: :brew"]} =
               Build.new(strategy: :brew, dir: "/o")
    end

    test "the none strategy needs nothing" do
      assert {:ok, %Build{strategy: :none}} = Build.new(strategy: :none)
    end
  end

  describe "cmake_command/1" do
    test "passes the user's arguments through verbatim and in order" do
      user = @source.cmake_args
      args = Build.cmake_command(@source)
      assert Enum.slice(args, 0, 4) == ["-S", "/src/llama.cpp", "-B", "/build/llama.cpp"]
      assert args == Enum.slice(args, 0, 4) ++ user
    end

    test "injects no architecture or GPU flag of its own" do
      # The whole point of the :source strategy. Given a plan with no user
      # arguments, we still must not guess an architecture: a Blackwell card
      # needs 120a, and no amount of detection on our side gets that right.
      bare = %Build{@source | cmake_args: []}
      args = Build.cmake_command(bare)

      refute Enum.any?(args, &String.contains?(&1, "CUDA_ARCH"))
      refute Enum.any?(args, &String.contains?(&1, "GGML_CUDA"))
      refute Enum.any?(args, &String.contains?(&1, "METAL"))
    end

    test "adds -S and -B from the configured directories" do
      args = Build.cmake_command(@source)
      pairs = Enum.chunk_every(args, 2, 1, :discard)
      assert ["-S", "/src/llama.cpp"] in pairs
      assert ["-B", "/build/llama.cpp"] in pairs
    end

    test "does not add a second build type when the user set one" do
      args = Build.cmake_command(@source)
      count = Enum.count(args, &String.starts_with?(&1, "-DCMAKE_BUILD_TYPE="))
      assert count == 1
    end

    test "adds a release build type when the user set none" do
      plan = %Build{@source | cmake_args: ["-DGGML_CUDA=ON"]}
      assert "-DCMAKE_BUILD_TYPE=Release" in Build.cmake_command(plan)
    end

    test "does not duplicate -S when the user already passed one" do
      plan = %Build{@source | cmake_args: ["-S", "/elsewhere"]}
      args = Build.cmake_command(plan)
      assert Enum.count(args, &(&1 == "-S")) == 1
      assert "-S" in args
    end
  end

  describe "generator_flag/1" do
    test "maps ninja and make to their cmake generators" do
      assert Build.generator_flag(@source) == "Ninja"
      assert Build.generator_flag(%{@source | generator: :make}) == "Unix Makefiles"
    end
  end

  describe "dir/1 and binary_path/2" do
    test "expands the directory" do
      assert Build.dir(%Build{@precompiled | dir: "~/llm"}) == System.user_home!() <> "/llm"
    end

    test "builds a binary path inside the directory" do
      assert Build.binary_path(@precompiled, "llama-server") == "/opt/llm/llama-server"
    end

    test "is nil without a directory" do
      assert Build.dir(%Build{@precompiled | dir: nil}) == nil
      assert Build.binary_path(%Build{@precompiled | dir: nil}, "llama-server") == nil
    end

    test "strategy is enforced, so a plan can never be ambiguous" do
      assert_raise ArgumentError, fn -> struct!(Build, dir: "/o") end
    end
  end

  describe "jobs/1" do
    test "jobs 0 means one per online scheduler" do
      assert Build.jobs(%{@source | jobs: 0}) == System.schedulers_online()
    end

    test "an explicit count is taken as given" do
      assert Build.jobs(%{@source | jobs: 3}) == 3
    end
  end

  describe "configure_command/1" do
    test "puts the declared generator in front of everything" do
      assert {"cmake", ["-G", "Ninja" | _rest]} = Build.configure_command(@source)

      assert {"cmake", ["-G", "Unix Makefiles" | _]} =
               Build.configure_command(%{@source | generator: :make})
    end

    test "still hands the user's arguments over verbatim, after ours" do
      {_exec, argv} = Build.configure_command(@source)
      ours = length(argv) - length(@source.cmake_args)
      assert Enum.slice(argv, ours, length(@source.cmake_args)) == @source.cmake_args
    end
  end

  describe "build_command/1" do
    test "uses --parallel, which both ninja and make understand" do
      assert {"cmake", argv} = Build.build_command(%{@source | jobs: 4})
      assert ["--build", "/build/llama.cpp", "--parallel", "4"] == argv
    end

    test "resolves jobs 0 before it reaches the command line" do
      assert {"cmake", argv} = Build.build_command(%{@source | jobs: 0})
      assert List.last(argv) == Integer.to_string(System.schedulers_online())
    end
  end

  describe "check/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "candil-check-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "is :ok when nothing was declared" do
      assert :ok = Build.check(%Build{strategy: :none})
    end

    test "reports every declared binary that is not there", %{dir: dir} do
      plan = %Build{@source | dir: dir, binaries: ["llama-server", "llama-cli"]}
      assert {:error, missing} = Build.check(plan)
      assert Enum.sort(missing) == ["llama-cli", "llama-server"]
    end

    test "counts a binary that lost its executable bit as missing", %{dir: dir} do
      File.write!(Path.join(dir, "llama-server"), "#!/bin/sh\n")
      File.chmod!(Path.join(dir, "llama-server"), 0o644)
      File.write!(Path.join(dir, "llama-cli"), "#!/bin/sh\n")
      File.chmod!(Path.join(dir, "llama-cli"), 0o755)

      plan = %Build{@source | dir: dir, binaries: ["llama-server", "llama-cli"]}
      assert {:error, ["llama-server"]} = Build.check(plan)
    end

    test "is :ok when every declared binary is present and executable", %{dir: dir} do
      for name <- ["llama-server", "llama-cli"] do
        path = Path.join(dir, name)
        File.write!(path, "#!/bin/sh\n")
        File.chmod!(path, 0o755)
      end

      plan = %Build{@source | dir: dir, binaries: ["llama-server", "llama-cli"]}
      assert :ok = Build.check(plan)
    end
  end

  describe "strategy :none" do
    test "install says there is nothing to do rather than pretending" do
      assert {:error, "nothing to install: strategy is :none"} =
               Build.install(%Build{strategy: :none})
    end
  end

  describe "binary_path/2 con un dir que en realidad es el binario" do
    # Escribir `dir = "~/.local/bin/llama-server"` cuando lo que se quiere
    # decir es `~/.local/bin` compone "/…/llama-server/llama-server", que no
    # falla hasta que `engine install` intenta meter un fichero dentro de un
    # fichero. El error tiene que salir antes y decir cual de las dos cosas
    # hacer.
    test "avisa cuando dir lleva el nombre del binario" do
      build = %Build{
        strategy: :source,
        dir: "~/.local/bin/llama-server",
        binaries: ["llama-server"]
      }

      assert_raise ArgumentError, ~r/directorio/i, fn ->
        Build.binary_path(build, "llama-server")
      end
    end

    test "avisa cuando dir parece un fichero" do
      build = %Build{
        strategy: :source,
        dir: "/opt/llm/llama-server.exe",
        binaries: ["llama-server"]
      }

      assert_raise ArgumentError, ~r/directorio/i, fn ->
        Build.binary_path(build, "llama-server")
      end
    end

    test "un directorio normal sigue funcionando" do
      build = %Build{strategy: :source, dir: "/opt/llm/bin", binaries: ["llama-server"]}
      assert Build.binary_path(build, "llama-server") == "/opt/llm/bin/llama-server"
    end
  end
end
