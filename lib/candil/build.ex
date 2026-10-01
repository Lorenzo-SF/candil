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

  ## Deliberately not here

  Nothing in this module links anything into `PATH`, and nothing decides
  compiler flags. A previous arrangement link-symlinked a whole virtualenv
  into `~/.local/bin` and put that virtualenv's `python3` ahead of the system
  one for every process on the machine. Point `Candil.Engine.binary` at
  `dir` instead.
  """

  alias Candil.Error

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
  Installs the binaries described by `build`.

  Bodies are filled in by the build phase; this is the contract.
  """
  @spec install(t(), keyword()) :: {:ok, %{path: binary()}} | {:error, term()}
  def install(%__MODULE__{} = _build, _opts \\ []) do
    {:error, Error.not_implemented("Candil.Build.install/2", phase: 2)}
  end

  @doc """
  Whether every declared binary is present and executable.
  """
  @spec check(t()) :: :ok | {:error, [binary()]}
  def check(%__MODULE__{}) do
    {:error, ["Candil.Build.check/1 is not implemented (phase 2)"]}
  end
end
