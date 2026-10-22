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
    match?({_out, 0}, cmd("nvidia-smi", ["-L"]))
  end

  def amd_available? do
    match?({_out, 0}, cmd("rocminfo", []))
  end

  def intel_arc_available? do
    System.find_executable("sycl-ls") != nil
  end

  def vulkan_available? do
    System.find_executable("vulkaninfo") != nil
  end

  def detect_cuda_version do
    case cmd("nvcc", ["--version"]) do
      {output, 0} ->
        case Regex.run(~r/release (\d+\.\d+)/, output) do
          [_, version] -> "cu#{String.replace(version, ".", "")}"
          _ -> nil
        end

      _ ->
        case cmd("nvidia-smi", ["--query-gpu=driver_version", "--format=csv,noheader"]) do
          {_out, 0} -> detect_cuda_from_driver()
          _ -> nil
        end
    end
  end

  @doc """
  Ejecuta un binario del sistema y devuelve su salida, o `:not_found`.

  ## Por qué no `System.cmd/3` a pelo

  `System.cmd/3` **no devuelve un error cuando el binario no existe: lanza
  una `ErlangError` con `:enoent`**. Y `nvcc` no está en todas las máquinas
  que tienen una GPU: el driver de NVIDIA se puede instalar sin el toolkit de
  CUDA, y entonces preguntar por la versión de CUDA era reventar.

  Medido el 2026-10-21: en el runner de CI (que tiene `nvidia-smi` y no tiene
  `nvcc`), Candil reventaba con un `ErlangError` al detectar el hardware. Es
  un crash de producción, no un problema de tests.

  El `rescue` también cubre el otro caso: un binario que existe pero no se
  puede ejecutar —un script con el shebang mal, o sin permiso— da `:enoent`
  también. Preguntar antes no es opcional: es la mitad del arreglo.
  """
  @spec cmd(String.t(), [String.t()]) :: {String.t(), integer()} | :not_found
  def cmd(binary, args) do
    case System.find_executable(binary) do
      nil ->
        :not_found

      path ->
        try do
          System.cmd(path, args, stderr_to_stdout: true)
        rescue
          ErlangError -> :not_found
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
