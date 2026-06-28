defmodule Candil.Model do
  @moduledoc """
  LLM model definition for Candil.

  A model is either **local** (a `.gguf` file on disk served by a local
  engine) or **remote** (a model name offered by a remote provider such as
  OpenAI or Anthropic).

  ## Local model fields

    * `:alias` — unique atom identifier
    * `:type` — `:local`
    * `:model_dir` — directory where the model file is stored
    * `:filename` — file name of the `.gguf` model (e.g. `"llama-3-8b.gguf"`)
    * `:download_url` — URL to download the model from (HuggingFace, etc.)
    * `:context_size` — context window in tokens (default: `4096`)
    * `:engine` — atom alias of the `Candil.Engine` to use
    * `:usage` — list of intended usages (see below)
    * `:model_args` — extra CLI args passed to the engine at model load time

  ## Remote model fields

    * `:alias` — unique atom identifier
    * `:type` — `:remote`
    * `:name` — provider model ID (e.g. `"gpt-4o"`, `"claude-opus-4-5"`)
    * `:context_size` — context window in tokens
    * `:provider` — atom alias of the `Candil.Provider` to use
    * `:usage` — list of intended usages

  ## Usage types

  `:chat`, `:completion`, `:embeddings`, `:reasoning`, `:vision`,
  `:code`, `:translation`, `:summarisation`
  """

  @type alias :: atom()

  @usage_types [
    :chat,
    :completion,
    :embeddings,
    :reasoning,
    :vision,
    :code,
    :translation,
    :summarisation
  ]

  @type model_type :: :local | :remote
  @type usage ::
          :chat
          | :completion
          | :embeddings
          | :reasoning
          | :vision
          | :code
          | :translation
          | :summarisation

  @enforce_keys [:alias, :type]

  defstruct alias: nil,
            type: :local,
            model_dir: nil,
            filename: nil,
            download_url: nil,
            checksum_sha256: nil,
            context_size: 4096,
            engine: nil,
            provider: nil,
            name: nil,
            usage: [:chat, :completion],
            model_args: []

  @type t :: %__MODULE__{
          alias: atom(),
          type: model_type(),
          model_dir: binary() | nil,
          filename: binary() | nil,
          download_url: binary() | nil,
          checksum_sha256: binary() | nil,
          context_size: pos_integer(),
          engine: atom() | nil,
          provider: atom() | nil,
          name: binary() | nil,
          usage: [usage()],
          model_args: [binary()]
        }

  @doc """
  Returns all valid usage type atoms.
  """
  @spec usage_types() :: [usage()]
  def usage_types, do: @usage_types

  @doc """
  Returns the full path to the model file on disk.

  Returns `nil` for remote models.
  """
  @spec file_path(t()) :: binary() | nil
  def file_path(%__MODULE__{type: :remote}), do: nil

  def file_path(%__MODULE__{model_dir: dir, filename: filename})
      when is_binary(dir) and is_binary(filename) do
    Path.join(dir, filename)
  end

  def file_path(_), do: nil

  @doc """
  Returns `true` if the model file exists on disk.

  Always returns `false` for remote models.
  """
  @spec downloaded?(t()) :: boolean()
  def downloaded?(%__MODULE__{type: :remote}), do: false

  def downloaded?(%__MODULE__{} = model) do
    case file_path(model) do
      nil -> false
      path -> File.exists?(path)
    end
  end

  @doc """
  Validates a model struct. Returns `:ok` or `{:error, [reasons]}`.
  """
  @spec validate(t()) :: :ok | {:error, [binary()]}
  def validate(%__MODULE__{} = model) do
    errors =
      []
      |> validate_alias(model)
      |> validate_type_fields(model)
      |> validate_usage(model)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp validate_alias(errors, %{alias: nil}), do: ["alias is required" | errors]
  defp validate_alias(errors, _), do: errors

  defp validate_type_fields(errors, %{type: :local} = m) do
    errors
    |> then(fn e ->
      if is_nil(m.engine), do: ["engine is required for local models" | e], else: e
    end)
    |> then(fn e ->
      if is_nil(m.model_dir), do: ["model_dir is required for local models" | e], else: e
    end)
    |> then(fn e ->
      if is_nil(m.filename), do: ["filename is required for local models" | e], else: e
    end)
  end

  defp validate_type_fields(errors, %{type: :remote} = m) do
    errors
    |> then(fn e ->
      if is_nil(m.provider), do: ["provider is required for remote models" | e], else: e
    end)
    |> then(fn e ->
      if is_nil(m.name), do: ["name is required for remote models" | e], else: e
    end)
  end

  defp validate_type_fields(errors, %{type: t}), do: ["unknown type: #{t}" | errors]

  defp validate_usage(errors, %{usage: usages}) when is_list(usages) do
    invalid = Enum.reject(usages, &(&1 in @usage_types))

    if invalid == [],
      do: errors,
      else: ["invalid usage types: #{inspect(invalid)}" | errors]
  end

  defp validate_usage(errors, _), do: ["usage must be a list" | errors]
end
