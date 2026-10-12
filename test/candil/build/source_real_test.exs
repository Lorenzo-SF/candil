defmodule Candil.Build.SourceRealTest do
  @moduledoc """
  The `:source` strategy against a real `cmake`, as opposed to the stand-in
  in `Candil.Build.SourceTest`.

  Both exist on purpose. The stand-in makes the suite hermetic and lets it
  assert the exact argv a process received, which is where C10 lives. What it
  cannot do is catch the gap between "our argv is right" and "cmake accepts
  that argv and does the thing" — a flag that only a real `cmake` validates, a
  build directory layout that only a real generator produces, a real compiler
  error on a real stderr.

  So this runs when `cmake` and `git` are on the `PATH`, and says plainly that
  it did not when they are not. A green run of the suite alone is not evidence
  that the toolchain path works; a green run of this file is.

  It is a few seconds, not the twenty to forty of a real CUDA `llama.cpp`:
  that one needs hardware this will never have, and it is a manual check.
  """

  use ExUnit.Case, async: true

  alias Candil.Build

  @cmake System.find_executable("cmake")
  @git System.find_executable("git")

  setup_all do
    if @cmake && @git do
      root = Path.join(System.tmp_dir!(), "candil-real-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      # Once, in setup_all: a second `git commit` on an already-committed
      # repository exits 1 with "nothing to commit", which is a confusing
      # failure for a test about cmake.
      %{
        root: root,
        good: repo_with_buildable_sources(root),
        broken: repo_with_broken_source(root)
      }
    else
      # LAS MISMAS CLAVES, aunque valgan `nil`.
      #
      # Antes esto devolvia `%{root: nil}` y el `describe` de abajo no se
      # definia: sin cmake la suite corria 878 tests en vez de 882, y ambos
      # greens decian "0 fallos" sobre **suites distintas**. Un recuento que
      # cambia con la maquina no es un recuento.
      #
      # Devolver las mismas claves deja que los tests se definan siempre y
      # decidan ellos mismos si se ejercitan o no.
      %{root: nil, good: nil, broken: nil}
    end
  end

  describe "against a real cmake" do
    @describetag :requires_cmake

    test "ninja builds, the binaries land in dir, and they run", ctx do
      if ejercitada?(ctx) do
        %{root: root, good: good} = ctx
        build = plan(root, good, :ninja)

        assert {:ok, %{path: path}} = Build.install(build)
        assert path == Build.dir(build)

        for name <- ["llama-server", "llama-cli"] do
          binary = Path.join(path, name)
          assert File.exists?(binary), "#{name} was not installed"

          {:ok, %File.Stat{mode: mode}} = File.stat(binary)
          assert Bitwise.band(mode, 0o111) != 0, "#{name} is not executable"

          # Exists and is executable is not the same as works.
          {output, 0} = System.cmd(binary, [], stderr_to_stdout: true)
          assert output =~ name
        end

        assert :ok = Build.check(build)
      else
        no_ejercitada("ninja builds, the binaries land in dir, and they run")
      end
    end

    test "the declared generator is the one that actually builds", ctx do
      if ejercitada?(ctx) do
        %{root: root, good: good} = ctx
        # Unix Makefiles, not ninja, under the same declaration.
        build = plan(root, good, :make)

        assert {:ok, _} = Build.install(build)
        assert File.exists?(Path.join(Build.dir(build), "llama-server"))
      else
        no_ejercitada("the declared generator is the one that actually builds")
      end
    end

    test "the user's cmake_args reach a real cmake, not just a stand-in", ctx do
      if ejercitada?(ctx) do
        %{root: root, good: good} = ctx

        # The fixture has an unused variable. `-Wall` is what makes the
        # compiler mention it — without it, `-Werror` has nothing to promote
        # and the build passes, which is a real trap rather than a subtle one.
        # Then -Werror turns that warning into a hard error. A stand-in would
        # have taken both flags and shrugged.
        strict = plan(root, good, :ninja, ["-DCMAKE_C_FLAGS=-Wall -Werror"])

        assert {:error, message} = Build.install(strict)
        assert message =~ "exited 1"
        assert message =~ "unused"

        # And the same project without the flag builds. That is the other half
        # of the claim: the failure above was the flag, not the project.
        lax = plan(root, good, :ninja, ["-DCMAKE_BUILD_TYPE=Release"])
        assert {:ok, _} = Build.install(lax)
      else
        no_ejercitada("the user's cmake_args reach a real cmake")
      end
    end

    test "a real compiler error comes back with its own stderr", ctx do
      if ejercitada?(ctx) do
        %{root: root, broken: broken} = ctx
        build = plan(root, broken, :ninja, [], binaries: ["llama-server"])

        assert {:error, message} = Build.install(build)

        # The failure is the compiler's, not ours. A summary on the way
        # through is a compiler error the user has to ask about instead of
        # read.
        assert message =~ "exited 1"
        assert message =~ "no_such_symbol_here"
        assert message =~ "main.c"
        assert message =~ "llama-server"

        refute File.exists?(Path.join(Build.dir(build), "llama-server"))
      else
        no_ejercitada("a real compiler error comes back with its own stderr")
      end
    end

    test "a second run reuses the clone and rebuilds", ctx do
      if ejercitada?(ctx) do
        %{root: root, good: good} = ctx
        build = plan(root, good, :ninja)

        assert {:ok, _} = Build.install(build)
        marker = Path.join(build.src_dir, "left-behind")
        File.write!(marker, "x")

        assert {:ok, _} = Build.install(build)
        assert File.exists?(marker), "src_dir was wiped instead of reused"
        assert :ok = Build.check(build)
      else
        no_ejercitada("a second run reuses the clone and rebuilds")
      end
    end
  end

  # Que el camino se haya ejercitado, o que se diga en voz alta que no.
  defp ejercitada?(%{root: nil}), do: false
  defp ejercitada?(_ctx), do: true

  # NO es un `flunk`: sin cmake esta maquina no puede ejercitar el camino, y
  # un rojo por un binario que no esta no habla de Candil (D-10). Pero el test
  # **existe**, cuenta, y dice en su salida que no se ha corrido — que es la
  # diferencia entre un verde que se puede reproducir y uno que no.
  defp no_ejercitada(nombre) do
    IO.puts("    ⏭  sin cmake/git en el PATH — NO se ha ejercitado: #{nombre}")
    :ok
  end

  defp plan(root, repo, generator, cmake_args \\ [], opts \\ []) do
    binaries = Keyword.get(opts, :binaries, ["llama-server", "llama-cli"])

    # The tag has to cover the arguments, not just how many there are. cmake
    # caches its configuration in `build_dir`, so two plans that differ only
    # in `cmake_args` but share a `build_dir` do not really differ: the second
    # one reuses the first one's cached flags, and the flag under test stops
    # being the flag that was configured.
    tag =
      :crypto.hash(:sha256, :erlang.term_to_binary({generator, cmake_args, binaries}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    {:ok, build} =
      Build.new(
        [
          strategy: :source,
          repo: repo,
          ref: "main",
          src_dir: Path.join([root, "src-#{tag}"]),
          build_dir: Path.join([root, "build-#{tag}"]),
          dir: Path.join([root, "bin-#{tag}"]),
          binaries: Keyword.get(opts, :binaries, ["llama-server", "llama-cli"]),
          generator: generator,
          jobs: 2,
          cmake_args: cmake_args
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      )

    build
  end

  # A real CMake project, committed to a real repository, that really builds.
  defp repo_with_buildable_sources(root) do
    path = Path.join(root, "upstream")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "CMakeLists.txt"), """
    cmake_minimum_required(VERSION 3.16)
    project(candil_fixture C)
    add_executable(llama-server main.c)
    add_executable(llama-cli cli.c)
    """)

    # `unused` is genuinely unused, so this project compiles with a warning
    # and fails with one. That is what lets a test prove the user's
    # cmake_args reached a real cmake: build it with -Werror and it has to
    # fail, which no stand-in would do.
    File.write!(
      Path.join(path, "main.c"),
      "#include <stdio.h>\nint main(void) { int unused = 1; printf(\"llama-server fixture\\n\"); return 0; }\n"
    )

    File.write!(
      Path.join(path, "cli.c"),
      "#include <stdio.h>\nint main(void) { int unused = 1; printf(\"llama-cli fixture\\n\"); return 0; }\n"
    )

    commit(path)
  end

  defp repo_with_broken_source(root) do
    path = Path.join(root, "broken")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "CMakeLists.txt"), """
    cmake_minimum_required(VERSION 3.16)
    project(candil_broken C)
    add_executable(llama-server main.c)
    """)

    File.write!(Path.join(path, "main.c"), "int main(void) { return no_such_symbol_here; }\n")

    commit(path)
  end

  defp commit(path) do
    {_, 0} = System.cmd(@git, ["init", "-q", "-b", "main", path], stderr_to_stdout: true)
    {_, 0} = System.cmd(@git, ["-C", path, "add", "."], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        @git,
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
end
