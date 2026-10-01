defmodule Candil.Source do
  @moduledoc """
  Where a model file comes from, and how to fetch it.

  A source replaces the old `Candil.Model.download_url` field. It is a value,
  not a process: describing where a file lives is data, and `fetch/2` turns
  that data into a file on disk.

  Three kinds:

    * `#{inspect("huggingface")}` — a HuggingFace repo plus a file path. Resolved
      over HTTPS against `huggingface.co`, so no `hf` CLI is required. That CLI
      is not installed everywhere, and relying on it made the download a
      separate failure mode from the download itself.
    * `#{inspect("url")}` — a direct URL to any tarball, release asset or mirror.
    * `#{inspect("local")}` — a path that is already on disk. `fetch/2` does
      nothing and only checks that the file is there.

  ## Absolute paths, always

  `dest` and `dest_name` are expanded with `Path.expand/1` before use, and the
  path handed to a process is absolute. `~` is not expanded inside a quoted
  argument, so a `"~/..."` string that reaches a spawned process becomes a
  literal directory named `~` in the current working directory. That bit the
  `--model-draft` argument in ropero and it is a rule for everything here too.

  ## Resumable, streaming, atomic

  `fetch/2` streams to a `.part` file, resumes with a `Range` header when one
  is already there, verifies the checksum incrementally, and renames into place
  only on success. A model file is commonly 17 GB; reading one into memory to
  hash it is not an option.
  """

  alias Candil.Error

  @enforce_keys [:kind]
  defstruct kind: nil,
            # huggingface
            repo: nil,
            file: nil,
            revision: "main",
            hf_token_env: nil,
            # url
            url: nil,
            # local
            path: nil,
            # shared
            dest: nil,
            dest_name: nil,
            sha256: nil

  @type kind :: :huggingface | :url | :local

  @type t :: %__MODULE__{
          kind: kind(),
          repo: binary() | nil,
          file: binary() | nil,
          revision: binary() | nil,
          hf_token_env: binary() | nil,
          url: binary() | nil,
          path: binary() | nil,
          dest: binary() | nil,
          dest_name: binary() | nil,
          sha256: binary() | nil
        }

  @doc """
  Builds a source from a keyword list or map, validating required fields.

  ## Examples

      iex> {:ok, source} = Candil.Source.new(
      ...>   kind: :huggingface, repo: "user/repo", file: "model.gguf", dest: "/models")
      iex> {source.kind, source.repo}
      {:huggingface, "user/repo"}

      iex> Candil.Source.new(kind: :huggingface, repo: "user/repo")
      {:error, ["file is required", "dest is required"]}
  """
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    source = struct(__MODULE__, attrs)

    case validate(source) do
      [] -> {:ok, source}
      errors -> {:error, errors}
    end
  end

  @doc """
  Returns the list of validation problems. Empty means valid.
  """
  @spec validate(t()) :: [String.t()]
  def validate(%__MODULE__{kind: :huggingface} = source) do
    []
    |> require_field(source.repo, :repo)
    |> require_field(source.file, :file)
    |> require_field(source.dest, :dest)
  end

  def validate(%__MODULE__{kind: :url} = source) do
    []
    |> require_field(source.url, :url)
    |> require_field(source.dest, :dest)
  end

  def validate(%__MODULE__{kind: :local} = source) do
    require_field([], source.path, :path)
  end

  def validate(%__MODULE__{kind: other}) do
    ["kind must be :huggingface, :url or :local, got: #{inspect(other)}"]
  end

  defp require_field(errors, value, name) when value in [nil, ""],
    do: errors ++ ["#{name} is required"]

  defp require_field(errors, _value, _name), do: errors

  @doc """
  The HTTPS URL this source resolves to, or `nil` for a local source.
  """
  @spec url(t()) :: binary() | nil
  def url(%__MODULE__{kind: :huggingface, repo: repo, file: file, revision: rev}) do
    "https://huggingface.co/#{repo}/resolve/#{rev || "main"}/#{file}"
  end

  def url(%__MODULE__{kind: :url, url: url}), do: url
  def url(%__MODULE__{kind: :local}), do: nil

  @doc """
  The file name this source lands as, inside `dest`.
  """
  @spec filename(t()) :: binary() | nil
  def filename(%__MODULE__{kind: :local, path: path}), do: Path.basename(path)

  def filename(%__MODULE__{dest_name: name}) when is_binary(name), do: Path.basename(name)

  def filename(%__MODULE__{kind: :huggingface, file: file}), do: Path.basename(file)

  def filename(%__MODULE__{url: url}) when is_binary(url),
    do: url |> URI.parse() |> path_basename()

  def filename(_source), do: nil

  defp path_basename(%URI{path: nil}), do: nil
  defp path_basename(%URI{path: path}), do: Path.basename(path)

  @doc """
  The absolute destination path, or `nil` for a local source.
  """
  @spec dest_path(t()) :: binary() | nil
  def dest_path(%__MODULE__{kind: :local}), do: nil

  def dest_path(%__MODULE__{dest: nil}), do: nil

  def dest_path(%__MODULE__{dest: dest, dest_name: dest_name} = source) do
    case filename(source) do
      nil -> nil
      file -> Path.join(Path.expand(dest), dest_name || file)
    end
  end

  @doc """
  Whether the file is already on disk and complete.
  """
  @spec present?(t()) :: boolean()
  def present?(%__MODULE__{kind: :local, path: path}) do
    is_binary(path) and File.regular?(Path.expand(path))
  end

  def present?(source) do
    case dest_path(source) do
      nil -> false
      path -> File.regular?(path) and File.stat!(path).size > 0
    end
  end

  @doc """
  The size in bytes of the local file, or `nil` when it is not there.
  """
  @spec size(t()) :: non_neg_integer() | nil
  def size(source) do
    case dest_path_or_local(source) do
      nil ->
        nil

      path ->
        case File.stat(path) do
          {:ok, %File.Stat{size: s}} -> s
          _ -> nil
        end
    end
  end

  defp dest_path_or_local(%__MODULE__{kind: :local, path: path}), do: path && Path.expand(path)
  defp dest_path_or_local(source), do: dest_path(source)

  @doc """
  Fetches the file, unless it is already present.

  Returns `{:ok, path}`. Idempotent: an existing, non-empty file short-circuits
  without a request.

  Bodies are filled in by the fetch phase; this is the contract.
  """
  @spec fetch(t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = _source, _opts \\ []) do
    {:error, Error.not_implemented("Candil.Source.fetch/2", phase: 1)}
  end

  @doc """
  Bytes written so far, for progress reporting from another process.
  """
  @spec progress(t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def progress(%__MODULE__{}) do
    {:error, Error.not_implemented("Candil.Source.progress/1", phase: 1)}
  end
end
