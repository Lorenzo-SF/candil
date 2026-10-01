defmodule Candil.Build do
  @moduledoc """
  How to get a usable `llama-server` binary, in one of two ways.

  `:precompiled` downloads a release asset that matches the detected OS,
  architecture and GPU. It is the quick path.

  `:source` clones the repository and compiles it with **your** `cmake_args`.
  It is the path that matters when the precompiled binary is wrong for your
  hardware, and it is a real case rather than a hypothetical one. A machine
  with a Blackwell GPU needs `-DCMAKE_CUDA_ARCHITECTURES=120a` plus the MXFP4
  and NVFP4 switches; a released generic binary is not tuned for that, and no
  amount of detection on our side produces the right answer. The person who
  knows the hardware is you, not this module.

  Which is why `cmake_args` is passed to `cmake` verbatim and we supply no
  defaults. Adding a sensible-looking default is how you end up with a binary
  that compiles, runs, and is quietly slow.

  ## `build_dir` remembers

  cmake caches its configuration in the build directory, including every flag
  it was given. So running `install/2` twice against the same `build_dir` with
  different `cmake_args` does not apply the new flags: the second run reuses
  the cache from the first. That is cmake's behaviour and not something this
  module papers over — silently deleting a build directory is how you lose
  twenty minutes of compiling. Change `build_dir`, or remove it yourself when
  you change the flags.

  ## Deliberately not here

  Nothing in this module links anything into `PATH`, and nothing decides
  compiler flags. A previous arrangement link-symlinked a whole virtualenv
  into `~/.local/bin` and put that virtualenv's `python3` ahead of the system
  one for every process on the machine. Point `Candil.Engine.binary` at
  `dir` instead.
  """

  alias Apero.Http
  alias Apero.Proc
  alias Candil.Detector

  # Generous: a release asset is hundreds of megabytes on a slow link, and a
  # download that gives up at the last megabyte is worse than a slow one.
  @download_timeout_ms 1_800_000

  # 1 MB. Big enough that the per-block overhead disappears, small enough that
  # re-hashing a partial download to resume it never matters.
  @hash_block_size 1_048_576

  @enforce_keys [:strategy]
  defstruct strategy: nil,
            # :precompiled
            version: :latest,
            sha256: nil,
            # :source
            repo: nil,
            ref: nil,
            src_dir: nil,
            build_dir: nil,
            generator: :ninja,
            jobs: 0,
            cmake_args: [],
            binaries: [],
            # shared
            dir: nil

  @type strategy :: :precompiled | :source | :none

  @type t :: %__MODULE__{
          strategy: strategy(),
          version: :latest | binary(),
          sha256: binary() | nil,
          repo: binary() | nil,
          ref: binary() | nil,
          src_dir: binary() | nil,
          build_dir: binary() | nil,
          generator: :ninja | :make,
          jobs: non_neg_integer(),
          cmake_args: [binary()],
          binaries: [binary()],
          dir: binary() | nil
        }

  @doc """
  Builds a build plan from a keyword list or map, validating required fields.

  ## Examples

      iex> {:ok, build} = Candil.Build.new(strategy: :precompiled, dir: "/opt/llm")
      iex> {build.strategy, build.dir}
      {:precompiled, "/opt/llm"}

      iex> Candil.Build.new(strategy: :source, dir: "/opt/llm")
      {:error, ["repo is required", "binaries is required"]}
  """
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    build = struct(__MODULE__, attrs)

    case validate(build) do
      [] -> {:ok, build}
      errors -> {:error, errors}
    end
  end

  @doc """
  Returns the list of validation problems. Empty means valid.
  """
  @spec validate(t()) :: [String.t()]
  def validate(%__MODULE__{strategy: :precompiled} = build) do
    case build.dir do
      nil -> ["dir is required for strategy :precompiled"]
      _ -> []
    end
  end

  def validate(%__MODULE__{strategy: :source} = build) do
    []
    |> require_field(build.repo, :repo)
    |> require_field(build.dir, :dir)
    |> require_nonempty(build.binaries, :binaries)
  end

  def validate(%__MODULE__{strategy: :none}), do: []

  def validate(%__MODULE__{strategy: other}),
    do: ["strategy must be :precompiled, :source or :none, got: #{inspect(other)}"]

  defp require_field(errors, value, name) when value in [nil, ""],
    do: errors ++ ["#{name} is required"]

  defp require_field(errors, _value, _name), do: errors

  # An empty list of binaries would build successfully and install nothing,
  # so it counts as a missing field rather than an empty one.
  defp require_nonempty(errors, value, name) when value in [nil, []],
    do: errors ++ ["#{name} is required"]

  defp require_nonempty(errors, _value, _name), do: errors

  @doc """
  The absolute directory where binaries are placed.
  """
  @spec dir(t()) :: binary() | nil
  def dir(%__MODULE__{dir: nil}), do: nil
  def dir(%__MODULE__{dir: dir}), do: Path.expand(dir)

  @doc """
  The full path of a named binary inside `dir`, or `nil` if unset.
  """
  @spec binary_path(t(), binary()) :: binary() | nil
  def binary_path(%__MODULE__{dir: nil}, _name), do: nil
  def binary_path(%__MODULE__{dir: dir}, name), do: Path.join(Path.expand(dir), name)

  @doc """
  The `cmake` arguments actually passed: ours, then the user's verbatim.

  We only add what cannot be expressed as a user argument and is not already
  there: the source directory, the build directory, and a release build type.
  Everything else is `cmake_args` exactly as given, in the order given, and
  last — `cmake` takes the last occurrence of a repeated flag, so anything we
  prepend can be overridden deliberately.
  """
  @spec cmake_command(t()) :: [binary()]
  def cmake_command(%__MODULE__{} = build) do
    user = build.cmake_args

    ours =
      []
      |> maybe_add_dir("-S", build.src_dir, user)
      |> maybe_add_dir("-B", build.build_dir, user)
      |> maybe_add_build_type(user)

    ours ++ user
  end

  defp maybe_add_dir(acc, _flag, nil, _user), do: acc

  defp maybe_add_dir(acc, flag, dir, user) do
    if flag in user, do: acc, else: acc ++ [flag, dir]
  end

  defp maybe_add_build_type(acc, user) do
    if Enum.any?(user, &String.starts_with?(&1, "-DCMAKE_BUILD_TYPE=")) do
      acc
    else
      acc ++ ["-DCMAKE_BUILD_TYPE=Release"]
    end
  end

  @doc """
  The generator flag for `cmake -G`.
  """
  @spec generator_flag(t()) :: binary()
  def generator_flag(%__MODULE__{generator: :make}), do: "Unix Makefiles"
  def generator_flag(%__MODULE__{generator: :ninja}), do: "Ninja"

  @doc """
  How many parallel compile jobs to use.

  `jobs: 0` means "one per online scheduler", which is the `nproc` the user
  would have typed by hand. Spelling it out here rather than shelling out to
  `nproc` keeps the answer testable.
  """
  @spec jobs(t()) :: pos_integer()
  def jobs(%__MODULE__{jobs: 0}), do: System.schedulers_online()
  def jobs(%__MODULE__{jobs: jobs}) when is_integer(jobs) and jobs > 0, do: jobs

  @doc """
  The configure invocation, as `{executable, argv}`.

  `cmake_command/1` plus the generator, ours first and the user's arguments
  last, so a `-G` or a build type in `cmake_args` still wins. This is a
  separate function rather than more of `cmake_command/1` because that one is
  the frozen contract for "ours, then the user's verbatim", and a test asserts
  it byte for byte.
  """
  @spec configure_command(t()) :: {binary(), [binary()]}
  def configure_command(%__MODULE__{} = build), do: {"cmake", configure_argv(build)}

  @doc """
  The compile invocation, as `{executable, argv}`.

  `--parallel` is the one spelling that works for both declared generators:
  cmake hands it to ninja as `-j` and to make as `-j`.
  """
  @spec build_command(t()) :: {binary(), [binary()]}
  def build_command(%__MODULE__{} = build), do: {"cmake", build_argv(build)}

  defp configure_argv(%__MODULE__{} = build) do
    ["-G", generator_flag(build)] ++ cmake_command(build)
  end

  defp build_argv(%__MODULE__{build_dir: nil}), do: []

  defp build_argv(%__MODULE__{} = build),
    do: ["--build", build.build_dir, "--parallel", Integer.to_string(jobs(build))]

  @doc """
  Installs the binaries described by `build`.

  Runs whichever strategy the plan declares. Both of them end with the same
  promise: the declared `binaries` exist under `dir` and are executable.

  ## Options

    * `:asset_url` — skip detection and download this URL instead. Useful for
      a pinned, unlisted build, and it is what makes the `:precompiled` path
      testable without the network.
    * `:cmake` — the `cmake` to drive, defaulting to whatever `cmake` is on the
      `PATH`. For a toolchain that is not there, like jtoolchain or a `cmake`
      behind a version manager.
    * `:on_output` — called with each chunk of combined stdout/stderr from
      `git` and `cmake`, so a CLI can show a twenty-minute build making
      progress.

  ## Cancellation

  The compiler is killed when the process that called `install/2` goes away,
  so closing the CLI mid-build does not leave a `cmake` running for another
  thirty minutes with nobody waiting for it. See `run/3` for what that does
  and does not cover.
  """
  @spec install(t(), keyword()) :: {:ok, %{path: binary()}} | {:error, term()}
  def install(build, opts \\ [])

  def install(%__MODULE__{strategy: :precompiled} = build, opts) do
    with {:ok, url} <- asset_url(build, opts),
         {:ok, archive} <- download(url, build),
         :ok <- extract(archive, build) do
      {:ok, %{path: dir(build)}}
    end
  end

  def install(%__MODULE__{strategy: :source} = build, opts) do
    on_output = Keyword.get(opts, :on_output)
    cmake = Keyword.get(opts, :cmake, "cmake")

    with {:ok, _} <- clone(build, on_output),
         {:ok, _} <- run!({cmake, configure_argv(build)}, on_output),
         {:ok, _} <- run!({cmake, build_argv(build)}, on_output),
         :ok <- collect(build, build.build_dir) do
      {:ok, %{path: dir(build)}}
    end
  end

  def install(%__MODULE__{strategy: :none}, _opts) do
    {:error, "nothing to install: strategy is :none"}
  end

  @doc """
  Whether every declared binary is present and executable.

  Returns `:ok`, or the names that are not. A file that exists but lost its
  executable bit counts as missing: `Candil.Engine` would fail to spawn it
  with a far less obvious error than the name of the file.
  """
  @spec check(t()) :: :ok | {:error, [binary()]}
  def check(%__MODULE__{} = build) do
    case Enum.reject(build.binaries, &installed?(build, &1)) do
      [] -> :ok
      missing -> {:error, missing}
    end
  end

  defp installed?(build, name) do
    case binary_path(build, name) do
      nil -> false
      path -> File.regular?(path) and executable?(path)
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # ── :source ──────────────────────────────────────────────────────────────

  # A populated `src_dir` is left alone rather than deleted and re-cloned.
  # `File.rm_rf/1` on a path that came out of a config file is the kind of
  # destructive default that has no business existing at all, and re-cloning a
  # multi-gigabyte repository on every invocation is its own problem.
  defp clone(%__MODULE__{} = build, on_output) do
    src = build.src_dir

    if populated?(src) do
      {:ok, "reusing #{src}"}
    else
      ref_args = if build.ref, do: ["-b", build.ref], else: []

      with :ok <- File.mkdir_p(Path.dirname(src)),
           {:ok, _} <-
             run!({"git", ["clone", "--depth", "1"] ++ ref_args ++ [build.repo, src]}, on_output) do
        {:ok, "cloned #{build.repo} into #{src}"}
      end
    end
  end

  defp populated?(nil), do: false
  defp populated?(path), do: File.dir?(path) and File.ls!(path) != []

  # ── :precompiled ─────────────────────────────────────────────────────────

  defp asset_url(build, opts) do
    case Keyword.get(opts, :asset_url) do
      nil -> Detector.asset_url(build.version)
      url when is_binary(url) -> {:ok, url}
    end
  end

  # `.part` plus a rename, and a `Range` request when the partial file is
  # already there. The rename is what makes a half-written archive
  # indistinguishable from a finished one, which is the property the rest of
  # Candil relies on.
  #
  # The checksum is folded in block by block as the bytes go past, for the same
  # reason `Candil.Source` will not read a 17 GB model into memory to hash it.
  # `Candil.Installer.verify_checksum/2` still does exactly that (B8, phase 0),
  # which is the other half of why this does not delegate to `Installer`.
  defp download(url, build) do
    dest = Path.join(dir(build), archive_name(url))
    part = dest <> ".part"

    with :ok <- File.mkdir_p(dir(build)),
         offset = file_size(part),
         {:ok, acc} <- transfer(url, part, offset),
         :ok <- expect_success(acc.status, offset),
         :ok <- verify(build.sha256, :crypto.hash_final(acc.ctx)),
         :ok <- File.rename(part, dest) do
      {:ok, dest}
    end
  end

  defp archive_name(url) do
    %URI{path: path} = URI.parse(url)
    Path.basename(path || "asset.zip")
  end

  # One request. The status arrives as the first event of the same response
  # that carries the body, so there is no second round trip to decide whether
  # the first one was worth making.
  defp transfer(url, part, offset) do
    case File.open(part, [:binary, :append]) do
      {:ok, io} ->
        acc = %{status: nil, ctx: seed_checksum(part)}
        headers = if offset > 0, do: [{"range", "bytes=#{offset}-"}], else: []

        try do
          Http.stream(
            :get,
            url,
            nil,
            headers,
            acc,
            &receive_chunk(&1, &2, io),
            receive_timeout: @download_timeout_ms
          )
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, "cannot open #{part}: #{inspect(reason)}"}
    end
  end

  defp receive_chunk({:status, status}, %{status: nil} = acc, _io),
    do: {:cont, %{acc | status: status}}

  defp receive_chunk({:status, _status}, acc, _io), do: {:cont, acc}

  defp receive_chunk({:data, data}, acc, io) do
    :ok = IO.binwrite(io, data)
    {:cont, %{acc | ctx: :crypto.hash_update(acc.ctx, data)}}
  end

  defp receive_chunk({:done, :done}, acc, _io), do: {:halt, acc}
  defp receive_chunk(_event, acc, _io), do: {:cont, acc}

  # A server that ignored the Range and answered 200 with the whole file would
  # otherwise have its bytes appended to the bytes already on disk, producing
  # a corrupt archive that looks complete. 200 is only the right answer when
  # there was nothing to resume from.
  defp expect_success(200, 0), do: :ok
  defp expect_success(206, _offset), do: :ok

  defp expect_success(status, offset) do
    {:error,
     "download resumed from byte #{offset} but the server answered HTTP #{status} with the " <>
       "whole file; appending it would corrupt the download"}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  # A resumed download cannot carry its hash state across a request, so the
  # bytes already on disk are folded back in — a block at a time, never the
  # whole file.
  defp seed_checksum(path) do
    ctx = :crypto.hash_init(:sha256)

    case File.open(path, [:binary, :read]) do
      {:ok, io} ->
        try do
          fold(io, ctx)
        after
          File.close(io)
        end

      _ ->
        ctx
    end
  end

  defp fold(io, ctx) do
    case IO.binread(io, @hash_block_size) do
      :eof ->
        ctx

      data when is_binary(data) ->
        fold(io, :crypto.hash_update(ctx, data))
    end
  end

  defp verify(nil, _digest), do: :ok

  defp verify(expected, digest) do
    actual = Base.encode16(digest, case: :lower)

    if actual == String.downcase(expected) do
      :ok
    else
      {:error, "SHA-256 mismatch: expected #{expected}, got #{actual}"}
    end
  end

  # llama.cpp ships its binaries under `build/bin/`, and the archive layout
  # has moved between releases, so the whole archive is staged and the declared
  # names are looked up by basename rather than by an assumed path.
  defp extract(archive, build) do
    staging = Path.join(dir(build), ".extract-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(staging),
         {:ok, _} <- run!({"unzip", ["-q", "-o", archive, "-d", staging]}, nil),
         :ok <- collect(build, staging) do
      File.rm_rf(staging)
      :ok
    end
  end

  # A build directory that exists is a clue, not a guarantee: `cmake --build`
  # can succeed and place nothing. Looking for the real file is the only check
  # that would have caught it.
  defp collect(build, root) do
    with :ok <- File.mkdir_p(dir(build)),
         {:ok, placed} <- place(build, root) do
      case Enum.reject(build.binaries, &(&1 in placed)) do
        [] -> :ok
        missing -> {:error, "the build did not produce: #{Enum.join(missing, ", ")}"}
      end
    end
  end

  defp place(build, root) do
    pattern = Path.join([root, "**", "{#{Enum.join(build.binaries, ",")}}"])
    found = Path.wildcard(pattern)

    names =
      Enum.map(found, fn path ->
        name = Path.basename(path)
        dest = binary_path(build, name)
        _ = File.mkdir_p(Path.dirname(dest))
        _ = File.rm(dest)
        _ = File.cp(path, dest)
        _ = File.chmod(dest, 0o755)
        name
      end)

    {:ok, names}
  end

  # ── Running external programs ────────────────────────────────────────────

  # The failure text is the program's own. A compiler error summarised on its
  # way through here is a compiler error the user has to ask about instead of
  # read.
  defp run!({exec, argv}, on_output) do
    case run(exec, argv, on_output) do
      {:ok, out} -> {:ok, out}
      {:error, {out, code}} -> {:error, "#{exec} exited #{code}\n#{String.trim(out)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
    end
  end

  # A port belongs to the emulator, not to the process that opened it. A dying
  # owner does not close its port, and a 20-minute cmake does not notice that
  # nobody is left waiting for it — verified, not assumed: killing the owner
  # left the child running until it was killed by hand.
  #
  # So the child is reaped explicitly. When the process that started the build
  # goes away, its OS pid is killed. That covers closing the CLI mid-build, an
  # exception, a supervisor shutdown, anything the VM still gets to run an exit
  # signal for.
  #
  # What it does not cover is `kill -9` on the whole VM, where no BEAM process
  # survives to do the killing. That one is not solvable from inside Erlang
  # without `prctl(PR_SET_PDEATHSIG)`, and pretending otherwise would be a
  # comment that lies.
  defp run(exec, argv, on_output) do
    case executable(exec) do
      nil ->
        {:error, "#{exec} is not on the PATH"}

      path ->
        # `Port.open/2` returns the port itself on OTP 28 and raises on
        # failure. A build that cannot start should say which command was
        # missing, not hand the caller an :enoent tuple from three frames up.
        try do
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(path)},
              [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv]
            )

          reaper = start_reaper(port, self())
          result = collect_port(port, [], on_output)
          stop_reaper(reaper)
          result
        rescue
          error -> {:error, "could not run #{exec}: #{Exception.message(error)}"}
        end
    end
  end

  # `spawn_executable` execs the name it is given rather than searching the
  # PATH, so `git` comes back as `:enoent` from a machine that has git
  # installed. Anything already spelled as a path is left alone.
  defp executable(exec) do
    if Path.type(exec) == :absolute, do: exec, else: Proc.which(exec)
  end

  defp start_reaper(port, owner) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        spawn(fn ->
          ref = Process.monitor(owner)

          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> kill(os_pid)
            {:stop, from} -> send(from, :stopped)
          end
        end)

      # No OS pid means no pid to kill. Windows, mostly.
      _ ->
        nil
    end
  end

  defp stop_reaper(nil), do: :ok

  defp stop_reaper(reaper) do
    send(reaper, {:stop, self()})
    receive do: (:stopped -> :ok), after: (1_000 -> :ok)
  end

  # `System.cmd/3` rather than a port: it goes through a shell, so `kill` is
  # found on the PATH the way every other command here is. A port would need
  # the absolute path spelled out by hand.
  defp kill(os_pid) do
    {_out, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  catch
    _kind, _reason -> :error
  end

  defp collect_port(port, acc, on_output) do
    receive do
      {^port, {:data, data}} ->
        if on_output, do: on_output.(data)
        collect_port(port, [data | acc], on_output)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, code}} ->
        {:error, {IO.iodata_to_binary(acc), code}}
    end
  end
end
