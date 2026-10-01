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

  describe "contract stubs" do
    test "install/2 returns an error naming the function" do
      assert {:error, %Candil.Error{reason: :not_implemented, context: context}} =
               Build.install(@source)

      assert context.function == "Candil.Build.install/2"
      assert context.phase == 2
    end

    test "check/1 returns the missing list its spec promises" do
      assert {:error, ["Candil.Build.check/1 is not implemented (phase 2)"]} =
               Build.check(@source)
    end
  end
end
