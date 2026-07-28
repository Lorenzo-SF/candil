defmodule Candil.Detector.GPU do
  @moduledoc false

  @type gpu_backend :: :cuda | :rocm | :metal | :vulkan | :sycl | :cpu

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

  def nvidia_available? do
    case System.find_executable("nvidia-smi") do
      nil -> false
      _ -> match?({_out, 0}, System.cmd("nvidia-smi", ["-L"], stderr_to_stdout: true))
    end
  end

  def amd_available? do
    case System.find_executable("rocminfo") do
      nil -> false
      _ -> match?({_out, 0}, System.cmd("rocminfo", [], stderr_to_stdout: true))
    end
  end

  def intel_arc_available? do
    System.find_executable("sycl-ls") != nil
  end

  def vulkan_available? do
    System.find_executable("vulkaninfo") != nil
  end

  def detect_cuda_version do
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
end
