defmodule Candil.Config.File do
  @moduledoc """
  Reading and writing `candil.toml`.

  Resolution order, lowest to highest:

    1. the defaults in each struct
    2. `config.exs`, via `Application.get_env/3` — still supported
    3. `candil.toml` — the source of truth

  The file wins because it is the newer mechanism. Someone with both has a
  `config.exs` they have not deleted yet, and their explicit file should mean
  something.

  A missing file is not an error. Candil starts with struct defaults and
  nothing configured, because a library that refuses to boot without a config
  file cannot be used as a library.

  ## Paths

  `default_path/0` is `~/.config/candil/candil.toml`, or whatever
  `CANDIL_CONFIG` points at. Every path derived from the file is expanded
  with `Path.expand/1` before use: `~` is not expanded inside a quoted
  argument, and a directory literally named `~` is not what anyone meant.
  """

  alias Candil.Config.Schema
  alias Candil.Error

  @default_path "~/.config/candil/candil.toml"

  @doc """
  The path the configuration is read from, honouring `CANDIL_CONFIG`.
  """
  @spec default_path() :: binary()
  def default_path do
    case System.get_env("CANDIL_CONFIG") do
      nil -> Path.expand(@default_path)
      "" -> Path.expand(@default_path)
      path -> Path.expand(path)
    end
  end

  @doc """
  Reads and validates the configuration file.

  Returns `{:ok, map}`, or `{:error, problems}` from the schema, or
  `{:error, {:io, reason}}` when the file exists but cannot be read.

  A missing file yields `{:ok, %{}}` rather than an error: Candil starts with
  struct defaults and nothing configured, because a library that refuses to
  boot without a config file cannot be used as a library.

  ## Examples

      iex> Candil.Config.File.default_path() |> String.ends_with?("candil.toml")
      true
  """
  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    load(default_path())
  end

  @doc """
  Reads and validates a specific path.
  """
  @spec load(binary()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, contents} ->
        case decode(contents, path) do
          {:ok, decoded} -> Schema.validate(decoded)
          {:error, _} = error -> error
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:io, reason}}
    end
  end

  @doc """
  Decodes TOML text, or explains why it could not be decoded.
  """
  @spec decode(binary(), binary() | nil) :: {:ok, map()} | {:error, term()}
  def decode(contents, path \\ nil) do
    case Toml.decode(contents) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, {:invalid, "could not parse #{where(path)}: #{inspect(reason)}"}}
    end
  end

  defp where(nil), do: "the TOML document"
  defp where(path), do: path

  @doc """
  Expands every path-looking string in the config so nothing downstream has
  to think about `~`.

  Returns a new map. The input is not modified.
  """
  @spec expand(map()) :: map()
  def expand(config) when is_map(config) do
    Map.new(config, fn {section, value} -> {section, expand_section(section, value)} end)
  end

  defp expand_section("engine", engines) when is_map(engines) do
    Map.new(engines, fn {name, spec} ->
      {name, expand_map(spec, &expand_engine/1)}
    end)
  end

  defp expand_section("model", models) when is_map(models) do
    Map.new(models, fn {name, spec} -> {name, expand_map(spec, &expand_model/1)} end)
  end

  defp expand_section("general", general) when is_map(general) do
    Map.new(general, fn {k, v} -> {k, maybe_expand(k, v)} end)
  end

  defp expand_section(_section, value), do: value

  defp expand_engine(spec) do
    spec
    |> maybe_expand_key("binary")
    |> expand_install()
  end

  defp expand_install(%{"install" => install} = spec) when is_map(install) do
    install =
      install
      |> maybe_expand_key("dir")
      |> maybe_expand_key("src_dir")
      |> maybe_expand_key("build_dir")

    Map.put(spec, "install", install)
  end

  defp expand_install(spec), do: spec

  defp expand_model(spec) do
    spec
    |> maybe_expand_key("model_dir")
    |> maybe_expand_key("filename")
    |> maybe_expand_key("base_url", false)
    |> expand_source()
  end

  # `source` and `draft` are both source tables, so they get the same
  # treatment: `dest` and `path` are filesystem paths and get expanded.
  #
  # They are handled independently rather than as two clauses. Two clauses with
  # one pattern each looks equivalent and is not: a model with a `source` never
  # reaches the `draft` clause, so its draft path kept a literal `~`. That is
  # the one model that has a draft at all, and a literal `~` there is the C22
  # trap — `--model-draft` arrives at llama-server between quotes.
  #
  # The keys are strings because the map came out of a TOML document. Matching
  # on atoms here is a mistake that compiles, passes the empty-document test,
  # and silently does nothing for every real config.
  defp expand_source(spec) when is_map(spec) do
    spec
    |> expand_source_key("source")
    |> expand_source_key("draft")
  end

  defp expand_source_key(spec, key) do
    case Map.get(spec, key) do
      source when is_map(source) -> Map.put(spec, key, expand_source_table(source))
      _ -> spec
    end
  end

  defp expand_source_table(source) do
    source |> maybe_expand_key("dest") |> maybe_expand_key("path")
  end

  # base_url is a URL, not a filesystem path, so it is left alone.
  defp maybe_expand_key(map, key), do: maybe_expand_key(map, key, true)

  defp maybe_expand_key(%{} = map, key, expand?) do
    case Map.get(map, key) do
      value when is_binary(value) and expand? -> Map.put(map, key, Path.expand(value))
      _ -> map
    end
  end

  defp maybe_expand(key, value), do: maybe_expand_key(%{key => value}, key) |> Map.get(key)

  defp expand_map(map, fun) when is_map(map) do
    case fun.(map) do
      %{} = result -> result
    end
  end

  @doc """
  Writes the configuration to `path`, atomically.

  Writes to a temporary file in the same directory and renames it, so a
  crash mid-write cannot leave a truncated `candil.toml` behind. That file is
  the source of truth; a truncated one is worse than a missing one.

  Not implemented yet — that is the write half of phase 1.
  """
  @spec save(map(), binary()) :: :ok | {:error, term()}
  def save(%{} = config, _path) do
    case Schema.validate(config) do
      {:ok, _} ->
        {:error, Error.not_implemented("Candil.Config.File.save/2", phase: 1)}

      {:error, problems} ->
        {:error, problems}
    end
  end
end
