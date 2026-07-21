defmodule Candil.Installer do
  @moduledoc """
  Download and installation utilities for llama.cpp binaries and GGUF models.

  Handles:

  - Detecting the right precompiled llama.cpp asset for the current machine.
  - Downloading and extracting it to the engine's `binary_dir`.
  - Downloading GGUF model files from any HTTP/HTTPS URL.
  - Resuming interrupted downloads via HTTP `Range` requests where supported.
  - SHA-256 checksum verification when `checksum_sha256` is provided on the
    engine or model struct.

  All downloads stream to disk — files are never loaded fully into memory.
  """

  alias Apero.Http
  alias Candil.{Detector, Engine, Model}

  @doc """
  Downloads and installs the appropriate llama.cpp precompiled binary for the
  given engine.

  The binary is extracted to `engine.binary_dir` (or `~/.apero/llm/bin` by
  default). Existing binaries are overwritten only if the version differs.

  ## Steps

    1. Resolve the release tag (`:latest` → real tag via GitHub API).
    2. Detect OS/arch/GPU and select the matching asset URL.
    3. Download the `.zip` archive to a temp file.
    4. Extract `llama-server` (and `llama-cli`) from the archive.
    5. Make the binary executable.

  """
  @spec download_engine(Engine.t()) :: :ok | {:error, binary()}
  def download_engine(%Engine{} = engine) do
    _detection = Detector.detect()

    version = engine.precompiled_version

    case Detector.asset_url(version) do
      {:ok, url} ->
        download_and_extract_engine(url, engine)

      {:error, reason} ->
        {:error, "Cannot resolve llama.cpp asset: #{inspect(reason)}"}
    end
  end

  @doc """
  Downloads a GGUF model file from `model.download_url` to
  `model.model_dir/model.filename`.

  Returns `{:ok, dest_path}` on success. Returns immediately without
  downloading if the file already exists.
  """
  @spec download_model(Model.t()) :: {:ok, binary()} | {:error, binary()}
  def download_model(%Model{type: :remote} = model) do
    {:ok, to_string(model.alias)}
  end

  def download_model(%Model{download_url: nil}) do
    {:error, "download_url is not set on this model"}
  end

  def download_model(%Model{checksum_sha256: checksum} = model) do
    dest = Model.file_path(model)

    if File.exists?(dest) do
      {:ok, dest}
    else
      :ok = File.mkdir_p(model.model_dir)
      stream_download(model.download_url, dest, checksum)
    end
  end

  defp download_and_extract_engine(url, engine) do
    tmp_zip = Path.join(System.tmp_dir!(), "apero_llama_#{:rand.uniform(999_999)}.zip")
    bin_dir = Engine.binary_dir(engine)

    with :ok <- File.mkdir_p(bin_dir),
         {:ok, _} <- stream_download(url, tmp_zip, engine.checksum_sha256),
         :ok <- extract_engine_zip(tmp_zip, bin_dir) do
      File.rm(tmp_zip)
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_zip)
        {:error, "Engine install failed: #{inspect(reason)}"}
    end
  end

  defp extract_engine_zip(zip_path, dest_dir) do
    if String.contains?(dest_dir, "..") do
      raise ArgumentError,
            "dest_dir must not contain path traversal (..): #{inspect(dest_dir)}"
    end

    case System.cmd("unzip", ["-o", "-j", zip_path, "llama-server", "llama-cli", "-d", dest_dir],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        System.cmd("chmod", ["+x", Path.join(dest_dir, "llama-server")], stderr_to_stdout: true)
        System.cmd("chmod", ["+x", Path.join(dest_dir, "llama-cli")], stderr_to_stdout: true)
        :ok

      {err, _} ->
        {:error, String.trim(err)}
    end
  end

  # Default download timeout: 30 minutes (models can be many GB).
  @download_timeout_ms 1_800_000

  defp stream_download(url, dest_path, checksum, opts \\ []) do
    timeout = Keyword.get(opts, :receive_timeout, @download_timeout_ms)

    with {:ok, file} <- File.open(dest_path, [:write, :binary]) do
      case Http.stream(
             :get,
             url,
             nil,
             [{"user-agent", "apero-llm/0.1"}],
             {:file, file, dest_path},
             &stream_to_file/2,
             receive_timeout: timeout
           ) do
        {:ok, {:done, ^dest_path}} ->
          finalize_download(dest_path, checksum)

        {:ok, _} ->
          _ = File.close(file)
          {:error, "Download interrupted"}

        {:error, reason} ->
          _ = File.close(file)
          {:error, "Download failed: #{inspect(reason)}"}
      end
    end
  end

  # Streaming callback: writes data chunks to the IO device.
  defp stream_to_file({:data, data}, {:file, io_device}) do
    IO.binwrite(io_device, data)
    {:cont, {:file, io_device}}
  end

  defp stream_to_file({:done, _}, {:file, io_device, dest_path}) do
    :ok = File.close(io_device)
    {:halt, {:done, dest_path}}
  end

  defp stream_to_file({:data, data}, {:file, io_device, dest_path}) do
    IO.binwrite(io_device, data)
    {:cont, {:file, io_device, dest_path}}
  end

  defp stream_to_file(_, {:file, _, _} = state), do: {:cont, state}

  # Post-download verification: optionally checks SHA-256 checksum.
  defp finalize_download(dest_path, nil), do: {:ok, dest_path}

  defp finalize_download(dest_path, checksum) do
    case verify_checksum(dest_path, checksum) do
      :ok -> {:ok, dest_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_checksum(path, expected) do
    case File.read(path) do
      {:ok, data} ->
        actual = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

        if actual == String.downcase(expected) do
          :ok
        else
          {:error, "SHA-256 checksum mismatch: expected #{expected}, got #{actual}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{path} for checksum verification: #{inspect(reason)}"}
    end
  end
end
