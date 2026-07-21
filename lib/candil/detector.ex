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

  alias Apero.Http

  @github_releases_url "https://api.github.com/repos/ggml-org/llama.cpp/releases"

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
    {gpu, cuda_version} = detect_gpu(os)

    %{
      os: os,
      arch: arch,
      gpu: gpu,
      cuda_version: cuda_version,
      asset_pattern: build_asset_pattern(os, arch, gpu, cuda_version)
    }
  end

  @doc """
  Returns the latest llama.cpp release tag from GitHub, or `{:error, reason}`
  if the API is unreachable.
  """
  @spec latest_release_tag() :: {:ok, binary()} | {:error, any()}
  def latest_release_tag do
    url = "#{@github_releases_url}/latest"

    case Http.get(
           url,
           [{"accept", "application/vnd.github+json"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} ->
        {:ok, tag}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Http.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the download URL for the best-matching asset in the given release,
  based on the current system's detection.

  Pass `:latest` as `version` to resolve the latest release automatically.
  """
  @spec asset_url(:latest | binary()) :: {:ok, binary()} | {:error, any()}
  def asset_url(:latest) do
    case latest_release_tag() do
      {:ok, tag} -> asset_url(tag)
      {:error, reason} -> {:error, reason}
    end
  end

  def asset_url(tag) when is_binary(tag) do
    detection = detect()
    url = "#{@github_releases_url}/tags/#{tag}"

    case Http.get(
           url,
           [{"accept", "application/vnd.github+json"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        find_matching_asset(assets, detection.asset_pattern)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Http.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the GPU backend detected on the current machine.
  """
  @spec detect_gpu(Apero.OS.os_type()) :: {gpu_backend(), binary() | nil}
  def detect_gpu(:macos), do: {:metal, nil}

  def detect_gpu(_os) do
    cond do
      nvidia_available?() -> {:cuda, detect_cuda_version()}
      amd_available?() -> {:rocm, nil}
      intel_arc_available?() -> {:sycl, nil}
      vulkan_available?() -> {:vulkan, nil}
      true -> {:cpu, nil}
    end
  end

  defp nvidia_available? do
    case System.find_executable("nvidia-smi") do
      nil -> false
      _ -> match?({_out, 0}, System.cmd("nvidia-smi", ["-L"], stderr_to_stdout: true))
    end
  end

  defp amd_available? do
    case System.find_executable("rocminfo") do
      nil -> false
      _ -> match?({_out, 0}, System.cmd("rocminfo", [], stderr_to_stdout: true))
    end
  end

  defp intel_arc_available? do
    System.find_executable("sycl-ls") != nil
  end

  defp vulkan_available? do
    System.find_executable("vulkaninfo") != nil
  end

  defp detect_cuda_version do
    case System.cmd("nvcc", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/release (\d+\.\d+)/, output) do
          [_, version] -> "cu#{String.replace(version, ".", "")}"
          _ -> nil
        end

      {_err, _} ->
        case System.cmd("nvidia-smi", ["--query-gpu=driver_version", "--format=csv,noheader"],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> detect_cuda_from_driver()
          _ -> nil
        end
    end
  end

  defp detect_cuda_from_driver do
    case File.read("/usr/local/cuda/version.txt") do
      {:ok, content} ->
        case Regex.run(~r/CUDA Version (\d+\.\d+)/, content) do
          [_, version] -> "cu#{String.replace(version, ".", "")}"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp build_asset_pattern(:linux, arch, :cuda, cuda_version) do
    arch_str = arch_string(arch)
    cuda_str = if cuda_version, do: "-#{cuda_version}", else: ""
    "bin-linux-cuda#{cuda_str}-#{arch_str}"
  end

  defp build_asset_pattern(:linux, arch, :rocm, _) do
    "bin-linux-rocm-#{arch_string(arch)}"
  end

  defp build_asset_pattern(:linux, arch, :vulkan, _) do
    "bin-linux-vulkan-#{arch_string(arch)}"
  end

  defp build_asset_pattern(:linux, arch, _, _) do
    "bin-ubuntu-#{arch_string(arch)}"
  end

  defp build_asset_pattern(:macos, :arm64, _, _), do: "bin-macos-arm64"
  defp build_asset_pattern(:macos, _, _, _), do: "bin-macos-x64"

  defp build_asset_pattern(:windows, arch, :cuda, cuda_version) do
    cuda_str = if cuda_version, do: "-#{cuda_version}", else: ""
    "bin-win-cuda#{cuda_str}-#{arch_string(arch)}"
  end

  defp build_asset_pattern(:windows, arch, _, _) do
    "bin-win-#{arch_string(arch)}"
  end

  defp build_asset_pattern(_, arch, _, _), do: "bin-linux-#{arch_string(arch)}"

  defp arch_string(:x86_64), do: "x64"
  defp arch_string(:arm64), do: "arm64"
  defp arch_string(:arm), do: "arm"
  defp arch_string(:i386), do: "x86"
  defp arch_string(_), do: "x64"

  defp find_matching_asset(assets, pattern) do
    match =
      Enum.find(assets, fn asset ->
        name = Map.get(asset, "name", "")
        String.contains?(name, pattern) and String.ends_with?(name, ".zip")
      end)

    case match do
      nil ->
        fallback = find_fallback_asset(assets)

        if fallback,
          do: {:ok, fallback["browser_download_url"]},
          else: {:error, :no_matching_asset}

      asset ->
        {:ok, asset["browser_download_url"]}
    end
  end

  defp find_fallback_asset(assets) do
    Enum.find(assets, fn asset ->
      name = Map.get(asset, "name", "")

      String.ends_with?(name, ".zip") and
        not String.contains?(name, "src") and
        not String.contains?(name, "sha256")
    end)
  end
end
