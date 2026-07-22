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

  @type gpu_backend :: :cuda | :rocm | :metal | :vulkan | :sycl | :cpu
  @type detection :: %{
          os: Apero.OS.os_type(),
          arch: Trebejo.OS.arch(),
          gpu: gpu_backend(),
          cuda_version: binary() | nil,
          asset_pattern: binary()
        }

  @doc """
  Detects OS, architecture and GPU backend.

  Returns a detection map with an `:asset_pattern` that can be used to select
  the right binary from a GitHub release.
  """
  @spec detect() :: detection()
  def detect do
    os = Apero.OS.type()
    arch = Trebejo.OS.arch()
    {gpu, cuda_version} = Candil.Detector.GPU.detect_gpu(os)

    %{
      os: os,
      arch: arch,
      gpu: gpu,
      cuda_version: cuda_version,
      asset_pattern: Candil.Detector.Models.build_asset_pattern(os, arch, gpu, cuda_version)
    }
  end

  @doc """
  Returns the latest llama.cpp release tag from GitHub, or `{:error, reason}`
  if the API is unreachable.
  """
  @spec latest_release_tag() :: {:ok, binary()} | {:error, any()}
  defdelegate latest_release_tag(), to: Candil.Detector.Release

  @doc """
  Returns the download URL for the best-matching asset in the given release,
  based on the current system's detection.

  Pass `:latest` as `version` to resolve the latest release automatically.
  """
  @spec asset_url(:latest | binary()) :: {:ok, binary()} | {:error, any()}
  defdelegate asset_url(:latest), to: Candil.Detector.Release
  defdelegate asset_url(tag), to: Candil.Detector.Release

  @doc """
  Returns the GPU backend detected on the current machine.
  """
  @spec detect_gpu(Apero.OS.os_type()) :: {gpu_backend(), binary() | nil}
  defdelegate detect_gpu(:macos), to: Candil.Detector.GPU
  defdelegate detect_gpu(os), to: Candil.Detector.GPU
end
