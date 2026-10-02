defmodule Candil.Detector do
  @moduledoc """
  System capability detection for llama.cpp precompiled binary selection.

  Inspects the current OS, CPU architecture and available GPU hardware to
  select the most appropriate precompiled binary from the
  [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases).

  ## Detection strategy

    1. OS type is read via `Apero.OS.type/0`; architecture via `Trebejo.OS.arch/0`.
    2. GPU detection tries, in order: NVIDIA (`nvidia-smi`), AMD (`rocminfo`),
       Apple Metal (via OS type), and Intel Arc (`sycl-ls`).
    3. The detected combination is mapped to the llama.cpp asset name pattern.

  ## Asset naming

  llama.cpp release assets follow this pattern:

      llama-<version>-bin-<platform>-<variant>-<arch>.zip

  For example:

      llama-b4561-bin-linux-cuda-cu12.4.1-x64.zip
      llama-b4561-bin-ubuntu-x64.zip
      llama-b4561-bin-macos-arm64.zip
      llama-b4561-bin-win-cuda-cu12.4.1-x64.zip
  """

  require Logger

  alias Candil.Detector.{GPU, Models, Release}

  @type gpu_backend :: :cuda | :rocm | :metal | :vulkan | :sycl | :cpu
  @type detection :: %{
          os: Apero.OS.os_type(),
          arch: any(),
          # :trebejo_not_available when the architecture could not be read.
          # `arch` falls back to :unknown, and that is why this is here.
          arch_error: :trebejo_not_available | nil,
          gpu: gpu_backend(),
          cuda_version: binary() | nil,
          asset_pattern: binary()
        }

  @doc """
  Detects OS, architecture and GPU backend.

  Returns a detection map with an `:asset_pattern` that can be used to select
  the right binary from a GitHub release.

  When Trebejo is not there to answer, `:arch` falls back to `:unknown` — the
  shape of the map does not change, because callers depend on it — but the
  reason travels with it in `:arch_error` and a warning is logged. The
  fallback used to be silent, and a silent `:unknown` is a wrong precompiled
  binary chosen three layers later, with nothing to connect it back to here.
  """
  @spec detect() :: detection()
  def detect do
    os = Apero.OS.type()
    {arch, arch_error} = arch()
    {gpu, cuda_version} = GPU.detect_gpu(os)

    if arch_error do
      Logger.warning(
        "#{inspect(__MODULE__)}: #{inspect(arch_error)}, so :arch is reported as :unknown and " <>
          "the precompiled asset will be picked without knowing the architecture. " <>
          "The download fails later and says nothing about this."
      )
    end

    %{
      os: os,
      arch: arch,
      arch_error: arch_error,
      gpu: gpu,
      cuda_version: cuda_version,
      asset_pattern: Models.build_asset_pattern(os, arch, gpu, cuda_version)
    }
  end

  @doc """
  The CPU architecture, or why it could not be read.

  Trebejo is an optional dep, so it may be absent at runtime even though the
  compiler knows about it. Guard, then call directly — an `apply/3` here was
  only there to silence the compiler, and it hid the very thing it was
  hiding: a missing Trebejo turning into a `:unknown` that nobody was told
  about.

  ## Examples

      iex> match?({:ok, _}, Candil.Detector.safe_arch()) or
      ...>   Candil.Detector.safe_arch() == {:error, :trebejo_not_available}
      true
  """
  @spec safe_arch() :: {:ok, atom()} | {:error, :trebejo_not_available}
  def safe_arch do
    if Code.ensure_loaded?(Trebejo.OS) and function_exported?(Trebejo.OS, :arch, 0) do
      {:ok, Trebejo.OS.arch()}
    else
      {:error, :trebejo_not_available}
    end
  end

  defp arch do
    case safe_arch() do
      {:ok, arch} -> {arch, nil}
      {:error, reason} -> {:unknown, reason}
    end
  end

  @doc """
  Returns the latest llama.cpp release tag from GitHub, or `{:error, reason}`
  if the API is unreachable.
  """
  @spec latest_release_tag() :: {:ok, binary()} | {:error, any()}
  defdelegate latest_release_tag(), to: Release

  @doc """
  Returns the download URL for the best-matching asset in the given release,
  based on the current system's detection.

  Pass `:latest` as `version` to resolve the latest release automatically.
  """
  @spec asset_url(:latest | binary()) :: {:ok, binary()} | {:error, any()}
  def asset_url(:latest), do: Release.asset_url(:latest)
  def asset_url(tag), do: Release.asset_url(tag)

  @doc """
  Returns the GPU backend detected on the current machine.
  """
  @spec detect_gpu(Apero.OS.os_type()) :: {gpu_backend(), binary() | nil}
  def detect_gpu(:macos), do: GPU.detect_gpu(:macos)
  def detect_gpu(os), do: GPU.detect_gpu(os)
end
