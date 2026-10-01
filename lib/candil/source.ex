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

  alias Apero.Http
  alias Candil.Error
  alias Plug.Crypto

  # 1 MB. Big enough that syscalls do not dominate, small enough that
  # verifying a 17 GB model never holds more than this.
  @checksum_block_bytes 1_048_576

  # 30 minutes. A 17 GB model over a slow link is a legitimate download, and
  # this is the gap between chunks, not the total.
  @default_receive_timeout 1_800_000

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
  def fetch(source, opts \\ [])

  def fetch(%__MODULE__{kind: :local} = source, _opts) do
    case dest_path_or_local(source) do
      nil -> {:error, Error.invalid_request("a local source needs a path")}
      path -> {:ok, path}
    end
  end

  def fetch(%__MODULE__{} = source, opts) do
    case dest_path(source) do
      nil ->
        {:error, Error.invalid_request("this source has no destination")}

      dest ->
        if present?(source) do
          {:ok, dest}
        else
          transfer_to(source, dest, opts)
        end
    end
  end

  # .part until it is whole, then renamed. A model directory holding a 4 GB
  # GGUF that is 90% there is worse than a missing one: every existence check
  # says it is there, and the failure surfaces much later, at load time.
  defp transfer_to(source, dest, opts) do
    :ok = File.mkdir_p(Path.dirname(dest))
    part = dest <> ".part"
    resume = partial_size(part)
    track_progress(dest, resume)

    case receive_stream(source, part, resume, opts) do
      {:ok, hash} -> commit(source, dest, part, hash, opts)
      {:error, reason} -> abort(part, dest, reason)
    end
  end

  defp partial_size(part) do
    case File.stat(part) do
      {:ok, %File.Stat{size: size}} when size > 0 -> size
      _ -> 0
    end
  end

  defp receive_stream(source, part, resume, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    case File.open(part, mode(resume)) do
      {:ok, file} ->
        hash = :crypto.hash_init(:sha256)
        # A resumed transfer starts mid-file, so the digest has to be seeded
        # with the bytes already on disk. Hashing only the new part and calling
        # it the whole file's digest would pass the wrong checksum roughly never.
        hash = seed_hash(hash, part, resume)
        state = %{file: file, hash: hash, dest: dest_of(part), written: resume}

        result =
          Http.stream(
            :get,
            url(source),
            nil,
            request_headers(source, resume),
            state,
            &consume/2,
            receive_timeout: timeout
          )

        _ = File.close(file)
        finish(result, state)

      {:error, reason} ->
        {:error, Error.invalid_request("cannot open #{part}: #{inspect(reason)}")}
    end
  end

  defp dest_of(part), do: String.replace_suffix(part, ".part", "")

  defp mode(0), do: [:write, :binary]

  # :append, and not [:read, :write]. Erlang's `read_write` TRUNCATES unless
  # `:no_truncate` is given, so a resumed download would overwrite the part it
  # already had and leave a file exactly half the right size — which passes
  # every existence check and fails at model load, hours later.
  defp mode(_offset), do: [:append, :binary]

  defp seed_hash(hash, _part, 0), do: hash

  defp seed_hash(hash, part, offset) do
    part |> hash_prefix(offset) |> then(&:crypto.hash_update(hash, &1))
  end

  defp hash_prefix(_part, offset) when offset <= 0, do: ""

  defp hash_prefix(part, offset) do
    case File.open(part, [:read, :binary]) do
      {:ok, file} ->
        data = read_n(file, offset, [])
        _ = File.close(file)
        IO.iodata_to_binary(data)

      {:error, _} ->
        ""
    end
  end

  defp read_n(_file, 0, acc), do: Enum.reverse(acc)
  defp read_n(_file, left, acc) when left <= 0, do: Enum.reverse(acc)

  defp read_n(file, left, acc) do
    case IO.binread(file, min(left, @checksum_block_bytes)) do
      data when is_binary(data) -> read_n(file, left - byte_size(data), [data | acc])
      _ -> Enum.reverse(acc)
    end
  end

  # Finch.stream/5 wraps this callback:
  #
  #     fun = fn entry, acc -> {:cont, fun.(entry, acc)} end
  #
  # so whatever this returns BECOMES the accumulator for the next chunk.
  # Returning `{:cont, state}` — which is what the Apero docs show and what
  # Candil.Installer does — nests the tuple on every chunk and the pattern
  # match fails on the second one. Return the bare state.
  #
  # The stream also opens with {:status, code} and {:headers, _} before any
  # data, so a callback that only knows :data raises on the first event of
  # every download.
  defp consume({:status, _code}, state), do: state
  defp consume({:headers, _headers}, state), do: state

  defp consume({:data, data}, state) do
    # data arrives as iodata, not necessarily a binary. File.write/3 calls
    # chardata_to_string/1 on it and raises on the list form.
    :ok = IO.binwrite(state.file, data)
    binary = IO.iodata_to_binary(data)

    state = %{
      state
      | written: state.written + byte_size(binary),
        hash: :crypto.hash_update(state.hash, binary)
    }

    track_progress(state.dest, state.written)
    state
  end

  defp consume(:done, state), do: state
  defp consume({:error, _reason}, state), do: %{state | aborted: true}

  defp finish({:ok, %{aborted: true}}, _fallback),
    do: {:error, Error.invalid_request("the transfer was aborted")}

  defp finish({:ok, %{hash: hash}}, _fallback) do
    {:ok, :crypto.hash_final(hash) |> Base.encode16(case: :lower)}
  end

  defp finish({:ok, _other}, _fallback),
    do: {:error, Error.invalid_request("the transfer ended with no data")}

  defp finish({:error, reason}, _fallback), do: {:error, Error.wrap(reason)}

  defp commit(source, dest, part, digest, opts) do
    if checksum_ok?(source, digest, opts) do
      :ok = File.rename(part, dest)
      clear_progress(dest)
      {:ok, dest}
    else
      abort(part, dest, Error.invalid_request("checksum mismatch for #{dest}"))
    end
  end

  defp checksum_ok?(%__MODULE__{sha256: nil}, _digest, _opts), do: true

  defp checksum_ok?(%__MODULE__{sha256: expected}, digest, _opts) do
    secure_equal?(digest, String.downcase(expected))
  end

  defp abort(part, dest, reason) do
    _ = File.rm(part)
    clear_progress(dest)
    {:error, reason}
  end

  @doc """
  Bytes written so far for a download, readable from another process.

  Returns `{:ok, 0}` when nothing is in flight, which is what a caller wants
  before a download starts as well as after one ends.
  """
  @spec progress(t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def progress(%__MODULE__{} = source) do
    case dest_path_or_local(source) do
      nil -> {:ok, 0}
      dest -> {:ok, :persistent_term.get(progress_key(dest), 0)}
    end
  end

  @doc """
  Clears the recorded progress for a source. Mostly for tests.
  """
  @spec reset_progress(t()) :: :ok
  def reset_progress(%__MODULE__{} = source) do
    case dest_path_or_local(source) do
      nil -> :ok
      dest -> clear_progress(dest)
    end
  end

  defp track_progress(dest, bytes) do
    :persistent_term.put(progress_key(dest), bytes)
    :ok
  end

  defp clear_progress(dest) do
    :persistent_term.erase(progress_key(dest))
    :ok
  end

  defp progress_key(dest), do: {__MODULE__, :progress, dest}

  # The Range header is the whole point of keeping a .part around. Without it
  # a resumed download asks for the whole file again and writes it on top of
  # what is already there.
  defp request_headers(source, 0), do: auth_headers(source)

  defp request_headers(source, offset),
    do: auth_headers(source) ++ [{"range", "bytes=#{offset}-"}]

  defp auth_headers(%__MODULE__{hf_token_env: nil}), do: []

  defp auth_headers(%__MODULE__{hf_token_env: var}) do
    case System.get_env(var) do
      nil -> []
      "" -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: Crypto.secure_compare(a, b)
  defp secure_equal?(_a, _b), do: false
end
