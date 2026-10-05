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

  alias Candil.Source

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

  @type model_type :: :local | :remote | :external
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
            # :local and :external
            engine: nil,
            # :remote
            provider: nil,
            name: nil,
            # :external — an engine we talk to but do not manage
            base_url: nil,
            # Where the file is, once it is on disk.
            model_dir: nil,
            filename: nil,
            # Where the file comes from, and the auxiliary file some models
            # need. `draft` is the speculative-decoding draft model, whose
            # path is handed to llama-server as an absolute path.
            source: nil,
            draft: nil,
            context_size: 4096,
            # Cuantas capas van a la GPU. Un CAMPO, no un flag suelto dentro
            # de `model_args`, y por dos razones que las dos duelen.
            #
            # Una: `candil run --cpu` tiene que poder apagarlo. Con el valor
            # escondido en una lista de strings no hay forma de tocarlo sin
            # reescribir un argv, y reescribir un argv exige saber que flags
            # llevan valor —cosa que no se sabe— asi que se acababa adivinando.
            #
            # Dos: la fuente de verdad son dos. Si esta aqui y tambien en
            # `model_args`, el `--cpu` pone una cosa y el engine lee otra, y
            # quien lee es llama-server. `build_args/2` quita el flag de
            # `model_args` y emite este campo, asi que hay una sola.
            #
            # -1 es el "quepa lo que quepa" de llama-server. 0 es CPU entera.
            gpu_layers: -1,
            # The port belongs to the model, not to the engine. One engine
            # serves many models, and the same model can run twice at once on
            # a GPU slot and a CPU slot.
            port: :auto,
            usage: [:chat, :completion],
            # An ordered list, not a map. llama-server takes the last
            # occurrence of a repeated flag, so order is behaviour.
            model_args: [],
            tags: [],
            checksum_sha256: nil,
            enabled: true

  # `port/0` is a built-in Erlang type and cannot be redefined.
  @type model_port :: :auto | :inet.port_number()

  @type t :: %__MODULE__{
          alias: atom(),
          type: model_type(),
          engine: atom() | nil,
          provider: atom() | nil,
          name: binary() | nil,
          base_url: binary() | nil,
          model_dir: binary() | nil,
          filename: binary() | nil,
          source: Source.t() | nil,
          draft: Source.t() | nil,
          context_size: pos_integer(),
          port: model_port(),
          usage: [usage()],
          model_args: [binary()],
          gpu_layers: integer(),
          tags: [binary() | atom()],
          checksum_sha256: binary() | nil,
          enabled: boolean()
        }

  @doc """
  Whether this model runs a process Candil manages, serves over a provider,
  or attaches to a server somebody else runs.
  """
  @spec managed?(t()) :: boolean()
  def managed?(%__MODULE__{type: :remote}), do: false
  def managed?(%__MODULE__{type: :external}), do: false
  def managed?(%__MODULE__{}), do: true

  @doc """
  Returns all valid usage type atoms.
  """
  @spec usage_types() :: [usage()]
  def usage_types, do: @usage_types

  @doc """
  Returns the full path to the model file on disk.

  Prefers the explicit `:model_dir` and `:filename`. When only a `:source` is
  given, the path is derived from it, so a model configured purely as "this
  HuggingFace repo and file" still knows where it will live.

  Returns `nil` for remote models and for anything without a locatable path.
  """
  @spec file_path(t()) :: binary() | nil
  def file_path(%__MODULE__{type: :remote}), do: nil

  def file_path(%__MODULE__{model_dir: dir, filename: filename})
      when is_binary(dir) and is_binary(filename) do
    if path_traversal?(dir) or path_traversal?(filename) do
      raise ArgumentError, "model_dir/filename must not contain path traversal (..)"
    end

    Path.join(dir, filename)
  end

  def file_path(%__MODULE__{source: %Candil.Source{kind: :local, path: path}})
      when is_binary(path) do
    if path_traversal?(path), do: nil, else: Path.expand(path)
  end

  def file_path(%__MODULE__{source: %Candil.Source{} = source}) do
    dest = Source.dest_path(source)
    if dest && path_traversal?(dest), do: nil, else: dest
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
      # Two different problems, two different messages. A path that escapes
      # the destination is worth naming specifically: it is either a typo or
      # an attack, and "not locatable" would hide which.
      #
      # The check goes through locatable?/1 rather than file_path/1 because
      # file_path/1 *raises* on traversal, and validation has to reject a
      # hostile path, not blow up on it. A validator that crashes on bad
      # input is not a validator.
      cond do
        traversal?(m) -> ["model_dir/filename must not contain path traversal (..)" | e]
        locatable?(m) -> e
        true -> ["model_dir/filename or source is required for local models" | e]
      end
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

  # An external model is a server somebody else runs. Candil talks HTTP to it
  # and never spawns anything, so it needs a URL to talk at and the engine that
  # carries the connection: no engine binary, no model file, no port to bind.
  #
  # It does NOT need a launcher. The launcher belongs to the engine, and
  # `Engine.launch/3` reads it from there. A model used to carry a `launcher`
  # field that no code ever read and validation nonetheless *required*, which
  # made the type unusable from the only place models come from: the schema
  # validates no `launcher` key and `Config.Hydrate` never read one, so an
  # external model in a TOML could not satisfy the requirement no matter how it
  # was written. Requiring a field nothing reads, that nothing can set, is a
  # deadlock wearing a field's clothes.
  defp validate_type_fields(errors, %{type: :external} = m) do
    errors
    |> then(fn e ->
      if is_nil(m.base_url), do: ["base_url is required for external models" | e], else: e
    end)
    |> then(fn e ->
      if is_nil(m.engine), do: ["engine is required for external models" | e], else: e
    end)
  end

  defp validate_type_fields(errors, %{type: t}), do: ["unknown type: #{t}" | errors]

  defp traversal?(%__MODULE__{model_dir: dir, filename: filename})
       when is_binary(dir) and is_binary(filename) do
    path_traversal?(dir) or path_traversal?(filename)
  end

  defp traversal?(%__MODULE__{source: %Candil.Source{kind: :local, path: path}})
       when is_binary(path),
       do: path_traversal?(path)

  defp traversal?(%__MODULE__{source: %Candil.Source{} = source}) do
    case Source.dest_path(source) do
      nil -> false
      dest -> path_traversal?(dest)
    end
  end

  defp traversal?(_), do: false

  defp locatable?(%__MODULE__{model_dir: dir, filename: filename})
       when is_binary(dir) and is_binary(filename) do
    not path_traversal?(dir) and not path_traversal?(filename)
  end

  defp locatable?(%__MODULE__{source: %Candil.Source{kind: :local, path: path}})
       when is_binary(path),
       do: not path_traversal?(path)

  defp locatable?(%__MODULE__{source: %Candil.Source{} = source}) do
    dest = Source.dest_path(source)
    dest != nil and not path_traversal?(dest)
  end

  defp locatable?(_), do: false

  # Rejects paths containing ".." to prevent directory traversal attacks.
  # Total on purpose: a nil or non-binary is not a traversal, and saying so
  # here is better than a FunctionClauseError from a private helper.
  @spec path_traversal?(term()) :: boolean()
  defp path_traversal?(path) when is_binary(path), do: String.contains?(path, "..")
  defp path_traversal?(_), do: false

  defp validate_usage(errors, %{usage: usages}) when is_list(usages) do
    invalid = Enum.reject(usages, &(&1 in @usage_types))

    if invalid == [],
      do: errors,
      else: ["invalid usage types: #{inspect(invalid)}" | errors]
  end

  defp validate_usage(errors, _), do: ["usage must be a list" | errors]
end
