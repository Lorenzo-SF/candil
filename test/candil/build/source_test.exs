defmodule Candil.Build.SourceTest do
  @moduledoc """
  The `:source` strategy: clone, configure, compile, collect.

  `cmake` and `ninja` are not installed on every machine that runs this suite,
  and a test that needs a twenty-minute CUDA compile is not a test. So the
  commands are a shell stand-in that records its argv verbatim and lays down the
  files a real `cmake --build` would. Everything the module is actually
  responsible for — the argv, the generator, the job count, the exit code, the
  cancellation — is still exercised for real, through a real process.
  """

  use ExUnit.Case, async: true

  alias Candil.Build

  @binaries ["llama-server", "llama-cli"]

  setup do
    root = Path.join(System.tmp_dir!(), "candil-build-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      System.delete_env("CANDIL_TEST_CMAKE_LOG")
      System.delete_env("CANDIL_TEST_CMAKE_PID")
      System.delete_env("CANDIL_TEST_CMAKE_SLEEP")
    end)

    log = Path.join(root, "cmake.log")
    System.put_env("CANDIL_TEST_CMAKE_LOG", log)

    {:ok, root: root, log: log, cmake: fake_cmake(root)}
  end

  defp fake_cmake(root) do
    path = Path.join(root, "fake-cmake")

    File.write!(path, """
    #!/bin/sh
    # A stand-in for cmake. Records the argv it was given, one argument per
    # line, separated by "--", so a test can assert what was actually passed.
    if [ -n "$CANDIL_TEST_CMAKE_LOG" ]; then
      for a in "$@"; do printf '%s\\n' "$a" >> "$CANDIL_TEST_CMAKE_LOG"; done
      printf -- '--\\n' >> "$CANDIL_TEST_CMAKE_LOG"
    fi

    if [ "$1" = "--build" ]; then
      if [ -n "$CANDIL_TEST_CMAKE_SLEEP" ]; then
        echo $$ > "$CANDIL_TEST_CMAKE_PID"
        sleep "$CANDIL_TEST_CMAKE_SLEEP"
      fi
      exit 0
    fi

    if [ -n "$CANDIL_TEST_CMAKE_FAIL" ]; then
      echo "CMake Error at CMakeLists.txt:7 (message):" >&2
      echo "  Target 'llama-server' requires CUDA 12" >&2
      exit 1
    fi

    if [ -n "$CANDIL_TEST_CMAKE_EMPTY" ]; then
      exit 0
    fi

    # Configure: pull the build directory out of "-B <dir>" and lay down the
    # executables the way a real build would, under bin/.
    build_dir=""
    previous=""
    for a in "$@"; do
      if [ "$previous" = "-B" ]; then build_dir="$a"; fi
      previous="$a"
    done

    mkdir -p "$build_dir/bin"
    for name in #{Enum.join(@binaries, " ")}; do
      printf '#!/bin/sh\\necho %s\\n' "$name" > "$build_dir/bin/$name"
      chmod +x "$build_dir/bin/$name"
    done
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp plan(root, overrides \\ []) do
    attrs =
      [
        strategy: :source,
        repo: fixture_repo(Path.join(root, "upstream")),
        ref: "main",
        src_dir: Path.join(root, "src"),
        build_dir: Path.join(root, "build"),
        dir: Path.join(root, "bin"),
        binaries: @binaries,
        generator: :ninja,
        jobs: 2,
        cmake_args: [
          "-DCMAKE_BUILD_TYPE=Release",
          "-DCMAKE_CUDA_ARCHITECTURES=120a",
          "-DGGML_CUDA=ON"
        ]
      ]
      |> Keyword.merge(overrides)

    {:ok, build} = Build.new(attrs)
    build
  end

  # A real repository, because `git clone` of a directory that is not one fails
  # in a way a fixture directory full of files does not.
  defp fixture_repo(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "CMakeLists.txt"), "cmake_minimum_required(VERSION 3.20)\n")
    File.write!(Path.join(path, "README.md"), "fixture\n")

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main", path], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", path, "add", "."], stderr_to_stdout: true)

    {_out, 0} =
      System.cmd(
        "git",
        [
          "-C",
          path,
          "-c",
          "user.email=fixture@example.test",
          "-c",
          "user.name=fixture",
          "commit",
          "-q",
          "-m",
          "fixture"
        ],
        stderr_to_stdout: true
      )

    path
  end

  defp invocations(log) do
    case File.read(log) do
      {:ok, contents} ->
        contents
        |> String.split("--\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.split(String.trim_trailing(&1, "\n"), "\n", trim: true))

      {:error, _} ->
        []
    end
  end

  describe "cmake_args are passed verbatim" do
    test "the user's arguments reach the process, in order, after ours", %{
      root: root,
      cmake: cmake,
      log: log
    } do
      build = plan(root)
      assert {:ok, _} = Build.install(build, cmake: cmake)

      [configure | _] = invocations(log)
      ours = length(configure) - length(build.cmake_args)
      assert Enum.slice(configure, ours, 3) == build.cmake_args
    end

    test "nothing is added that the user did not ask for", %{root: root, cmake: cmake, log: log} do
      build = plan(root, cmake_args: [])
      assert {:ok, _} = Build.install(build, cmake: cmake)

      [configure | _] = invocations(log)

      ours = [
        "-G",
        "Ninja",
        "-S",
        build.src_dir,
        "-B",
        build.build_dir,
        "-DCMAKE_BUILD_TYPE=Release"
      ]

      assert configure == ours
    end

    test "no architecture or GPU flag is ever invented", %{root: root, cmake: cmake, log: log} do
      build = plan(root, cmake_args: [])
      assert {:ok, _} = Build.install(build, cmake: cmake)

      [configure | _] = invocations(log)

      refute Enum.any?(configure, &String.contains?(&1, "CUDA_ARCH"))
      refute Enum.any?(configure, &String.contains?(&1, "GGML_CUDA"))
    end
  end

  describe "the declared generator" do
    test "ninja is asked for with -G", %{root: root, cmake: cmake, log: log} do
      assert {:ok, _} = Build.install(plan(root, generator: :ninja), cmake: cmake)
      [configure | _] = invocations(log)
      assert Enum.chunk_every(configure, 2, 1, :discard) |> Enum.member?(["-G", "Ninja"])
    end

    test "make is asked for with -G", %{root: root, cmake: cmake, log: log} do
      assert {:ok, _} = Build.install(plan(root, generator: :make), cmake: cmake)
      [configure | _] = invocations(log)
      assert Enum.chunk_every(configure, 2, 1, :discard) |> Enum.member?(["-G", "Unix Makefiles"])
    end

    test "--build is a separate invocation of the same tool", %{
      root: root,
      cmake: cmake,
      log: log
    } do
      build = plan(root, jobs: 5)
      assert {:ok, _} = Build.install(build, cmake: cmake)

      [_configure, compile] = invocations(log)
      assert ["--build", build.build_dir, "--parallel", "5"] == compile
    end
  end

  describe "jobs" do
    test "0 becomes one per online scheduler, which is the nproc", %{
      root: root,
      cmake: cmake,
      log: log
    } do
      assert {:ok, _} = Build.install(plan(root, jobs: 0), cmake: cmake)
      [_configure, compile] = invocations(log)
      assert List.last(compile) == Integer.to_string(System.schedulers_online())
    end
  end

  describe "the result" do
    test "clones the repository, compiles, and leaves the binaries in dir", %{
      root: root,
      cmake: cmake
    } do
      build = plan(root)

      assert {:ok, %{path: path}} = Build.install(build, cmake: cmake)
      assert path == Build.dir(build)
      assert File.dir?(build.src_dir)
      assert File.exists?(Path.join(build.src_dir, "CMakeLists.txt"))
    end

    test "the binaries are copied and executable", %{root: root, cmake: cmake} do
      build = plan(root)
      assert {:ok, _} = Build.install(build, cmake: cmake)

      for name <- @binaries do
        path = Path.join(Build.dir(build), name)
        assert File.exists?(path), "#{name} was not installed"
        assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
        assert Bitwise.band(mode, 0o111) != 0, "#{name} is not executable"
      end
    end

    test "check/1 is :ok afterwards", %{root: root, cmake: cmake} do
      build = plan(root)
      assert {:ok, _} = Build.install(build, cmake: cmake)
      assert :ok = Build.check(build)
    end

    test "a build that produces nothing is reported, not passed off", %{root: root, cmake: cmake} do
      System.put_env("CANDIL_TEST_CMAKE_EMPTY", "1")
      on_exit(fn -> System.delete_env("CANDIL_TEST_CMAKE_EMPTY") end)

      build = plan(root)

      assert {:error, message} = Build.install(build, cmake: cmake)
      assert message =~ "did not produce"
      assert message =~ "llama-server"
    end

    test "an already-populated src_dir is reused rather than re-cloned", %{
      root: root,
      cmake: cmake
    } do
      build = plan(root)
      assert {:ok, _} = Build.install(build, cmake: cmake)
      first = File.ls!(build.src_dir)

      marker = Path.join(build.src_dir, "not-from-the-clone")
      File.write!(marker, "x")

      assert {:ok, _} = Build.install(build, cmake: cmake)
      assert File.exists?(marker), "src_dir was wiped and re-cloned"
      assert first == Enum.reject(File.ls!(build.src_dir), &(&1 == "not-from-the-clone"))
    end

    test "an existing build directory does not skip the compile", %{
      root: root,
      cmake: cmake,
      log: log
    } do
      build = plan(root)
      assert {:ok, _} = Build.install(build, cmake: cmake)
      assert length(invocations(log)) == 2

      assert {:ok, _} = Build.install(build, cmake: cmake)
      assert length(invocations(log)) == 4
    end
  end

  describe "when cmake fails" do
    setup do
      System.put_env("CANDIL_TEST_CMAKE_FAIL", "1")
      on_exit(fn -> System.delete_env("CANDIL_TEST_CMAKE_FAIL") end)
      :ok
    end

    test "the error comes back with cmake's own stderr in it", %{root: root, cmake: cmake} do
      assert {:error, message} = Build.install(plan(root), cmake: cmake)
      assert message =~ "requires CUDA 12"
      assert message =~ "CMakeLists.txt:7"
    end

    test "the exit status is not hidden behind a generic failure", %{root: root, cmake: cmake} do
      assert {:error, message} = Build.install(plan(root), cmake: cmake)
      assert message =~ "exited 1"
    end
  end

  describe "cancellation" do
    test "killing the caller kills the compiler", %{root: root, cmake: cmake} do
      build = plan(root)
      pid_file = Path.join(root, "cmake.pid")
      System.put_env("CANDIL_TEST_CMAKE_PID", pid_file)
      System.put_env("CANDIL_TEST_CMAKE_SLEEP", "60")

      {owner, ref} =
        spawn_monitor(fn ->
          send(:candil_build_test_caller, {:result, Build.install(build, cmake: cmake)})
        end)

      os_pid = await_pid_file(pid_file)
      assert File.dir?("/proc/#{os_pid}"), "the compiler was never running"

      # Closing the CLI is the owner going away. Nothing else.
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000

      assert eventually_gone?(os_pid),
             "cmake (pid #{os_pid}) outlived the process that started it"
    end

    test "a build that finishes on its own is not killed by the reaper" do
      # The reaper watches the caller, and the caller outliving the build is
      # the normal case. If this regressed, every install would be cancelled.
      root = Path.join(System.tmp_dir!(), "candil-reaper-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      log = Path.join(root, "cmake.log")
      System.put_env("CANDIL_TEST_CMAKE_LOG", log)
      cmake = fake_cmake(root)

      build = plan(root)
      assert {:ok, _} = Build.install(build, cmake: cmake)
      assert length(invocations(log)) == 2
    end
  end

  defp await_pid_file(path, tries \\ 100) do
    cond do
      File.exists?(path) ->
        String.trim(File.read!(path))

      tries > 0 ->
        Process.sleep(50)
        await_pid_file(path, tries - 1)

      true ->
        flunk("the compiler never reported its pid (looked in #{path})")
    end
  end

  # A killed process lingers as a zombie until its parent reaps it, and a
  # zombie still has a /proc entry. "Gone" means actually gone.
  defp eventually_gone?(os_pid, tries \\ 100) do
    gone? = fn ->
      case File.read("/proc/#{os_pid}/stat") do
        {:error, _} -> true
        {:ok, stat} -> stat |> String.split(" ") |> Enum.at(2) == "Z"
      end
    end

    cond do
      gone?.() ->
        true

      tries > 0 ->
        Process.sleep(50)
        eventually_gone?(os_pid, tries - 1)

      true ->
        false
    end
  end
end
