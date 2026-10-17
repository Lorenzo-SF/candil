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
    * `:description` — what this model is for, in one sentence

  ## Remote model fields

    * `:alias` — unique atom identifier
    * `:type` — `:remote`
    * `:name` — provider model ID (e.g. `"gpt-4o"`, `"claude-opus-4-5"`)
    * `:context_size` — context window in tokens
    * `:provider` — atom alias of the `Candil.Provider` to use
    * `:usage` — list of intended usages
    * `:description` — what this model is for, in one sentence

  ## `description` no es la carta de presentación

  Es **lo único que la capa `:embedding` del router tiene para comparar con un
  prompt** (`Candil.Router.Scorer`). Sin ella, esa capa no puede comparar nada
  y devuelve `:miss`: no compara con el alias, ni con el nombre del fichero, ni
  con una descripción inventada a partir del nombre, porque un 0 de similitud
  sacado de un texto que nadie escribió no es una medida: es ruido con
  decimales.

  Es opcional, y por omisión no se inventa. Un modelo sin descripción
  simplemente no entra en la comparación de esa capa.

  ## `usage` y `capabilities`: dos preguntas distintas

  Antes de esto eran una sola lista y no se podia contestarla bien. Medido el
  2026-10-14 sobre el catálogo real: cuatro modelos declaraban
  `usage = ["chat", "reasoning"]` o `usage = ["chat", "code", "completion"]`, y
  en esa lista **`chat` y `completion` son endpoints y `reasoning` y `code` no
  lo son**. El codigo los usaba igual y con dos semanticas distintas: el
  `DecisionEngine` preguntaba `:chat in usage` (endpoint, puedo servir
  peticiones) y el `Scorer` preguntaba `:reasoning in usage` (capacidad, este
  modelo es bueno para razonar).

  Asi que ahora son dos campos, y cada uno contesta una pregunta:

  | Campo | Pregunta | Valores |
  |---|---|---|
  | `:usage` | **que endpoints** puedo servir | `:chat`, `:completion`, `:embeddings` |
  | `:capabilities` | **para que** es bueno | `:code`, `:reasoning`, `:vision`, `:translation`, `:redaction`, `:summarisation` |

  `:usage` sigue siendo obligatoria por defecto (`[:chat, :completion]`) porque
  es lo que decide si a este modelo se le puede pedir una peticion.
  `:capabilities` **no se inventa**: el defecto es `[]`, y un modelo sin
  capacidades no se considera bueno para nada en particular, que es distinto de
  considerarlo bueno para todo.

  Un valor que no este en ninguna de las dos listas **es un error al cargar**,
  no se ignora. Un catalogo que dice `"uso": "chatt"` y no dice nada no es un
  catalogo honesto, es una letra que nadie lee y un modelo que nadie usa.

  ## Lo que se migra, y lo que no

  Un `usage` viejo que mezcle las dos cosas **arranca igual**: cada elemento
  conocido va a donde le toca (endpoint a `usage`, capacidad a `capabilities`)
  y se avisa con un warning que dice a donde fue. Un elemento desconocido si es
  un error, porque migrar a ciegas seria inventar.

  Los valores que se reconocen como capacidad, y por tanto migran solos, son
  `code`, `reasoning`, `vision`, `translation`, `redaction` y `summarisation`.
  """

  alias Candil.Source

  @type alias :: atom()

  # Los endpoints que puede servir un destino. Es lo unico que decide si se le
  # puede pedir una peticion.
  @usage_types [:chat, :completion, :embeddings]

  # Para que es bueno un destino. No decide si se le puede pedir nada: eso es
  # `usage`. Decide a quien le encaja cuando hay varios candidatos.
  @capability_types [:code, :reasoning, :vision, :translation, :redaction, :summarisation]

  @type model_type :: :local | :remote | :external
  @type usage :: :chat | :completion | :embeddings
  @type capability ::
          :code
          | :reasoning
          | :vision
          | :translation
          | :redaction
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
            # PARA QUE es bueno, que es otra pregunta que la de `usage`. El
            # defecto es `[]` y no se inventa: un modelo sin capacidades no se
            # considera bueno para nada en particular, que es distinto de
            # considerarlo bueno para todo. Lo consulta el filtro de dificultad
            # del router (`:deep` quiere `:reasoning`, `:fast` la excluye).
            capabilities: [],
            # QUE SABE HACER, en una frase. No es decoracion: es el texto que
            # la capa `:embedding` del router compara con el prompt, y sin el
            # no hay nada comparable. Opcional a proposito —ver el `@moduledoc`—
            # y `nil` significa que este modelo no participa en esa capa.
            description: nil,
            # EXCLUSIVO: si este destino se puede usar a la vez que otro.
            #
            # `false` —el defecto— significa que **no hay cola**: el que pide
            # pasa de largo. Una API no se estorba consigo misma, y una GPU
            # libre tampoco.
            #
            # `true` significa que **si lo tiene uno, no caben dos**: una GPU
            # con un modelo de 12 GB. Ahi la peticion espera su turno, y el
            # orden lo decide `Candil.Policy`.
            #
            # Opcional a proposito y **el schema NO lo exige**: el defecto tiene
            # que ser el aburrido, el que no toca la cola. Un interruptor global
            # obligaria a elegir un modo para todos los destinos, siendo malo
            # para casi todos.
            exclusive: false,
            # An ordered list, not a map. llama-server takes the last
            # occurrence of a repeated flag, so order is behaviour.
            model_args: [],
            tags: [],
            enabled: true,
            # Cuanto tarda este destino de verdad, en segundos. Lo usa
            # `Candil.Refusal.wait_timeout_ms/2`: con esto declarado, el tope de
            # espera de ESTE destino es el doble de su latencia tipica, en vez
            # del 60 s global. Sin esto, un 70B en CPU que tarda 120 s por
            # inferencia se queda sinesperar nunca.
            #
            # En segundos y no en milisegundos porque es lo que se escribe a
            # mano en el toml, y 120 se lee mejor que 120_000.
            typical_latency_s: nil

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
          capabilities: [capability()],
          description: binary() | nil,
          model_args: [binary()],
          gpu_layers: integer(),
          tags: [binary() | atom()],
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
  Los endpoints que un modelo puede servir. Un solo sitio donde viven.

  **Solo endpoints.** Para que es bueno el modelo va en `capabilities/0`, que
  es otra pregunta; ver el `@moduledoc`.
  """
  @spec usage_types() :: [usage()]
  def usage_types, do: @usage_types

  @doc """
  Las capacidades de un modelo, y donde migran solas las que estaban en
  `usage`. Un solo sitio donde viven.
  """
  @spec capability_types() :: [capability()]
  def capability_types, do: @capability_types

  @doc """
  Separa una lista de `usage` viejo en `{endpoints, capacidades}`.

  Es la **migracion**, en un solo sitio: lo usan el `Hydrate` —que avisa— y
  quien construye un `%Model{}` a mano —que no puede avisar porque ya sabe lo
  que hace—. Un endpoint se queda, una capacidad se va a su sitio, y lo que no
  esta en ninguna de las dos listas no se inventa: se queda fuera y el que llama
  decide, que es lo que evita que un typo se convierta en un modelo que finge.

  Los valores ya atomizados se aceptan igual que los strings, porque un
  `%Model{}` se construye con atomos y un toml con strings.
  """
  @spec split_usage([atom() | binary()]) :: {valid_usage, valid_capabilities, invalid}
        when valid_usage: [usage()],
             valid_capabilities: [capability()],
             invalid: [binary()]
  def split_usage(values) when is_list(values) do
    Enum.reduce(values, {[], [], []}, fn value, {e, c, i} ->
      case atom_de(value) do
        nil -> {e, c, [inspeccion(value) | i]}
        v when v in @usage_types -> {[v | e], c, i}
        v -> {e, [v | c], i}
      end
    end)
    |> then(fn {e, c, i} -> {Enum.reverse(e), Enum.reverse(c), Enum.reverse(i)} end)
  end

  def split_usage(otro), do: {[], [], [inspeccion(otro)]}

  # El atomo de un valor escrito, **solo si ya existe**: se busca en las dos
  # listas de este modulo comparando el texto, no con `String.to_atom`, que
  # crearia el atomo y lo dejaria en la tabla para siempre con un string que
  # solo vino de un fichero.
  #
  # Y si el valor no es ni texto ni atomo —un mapa, una lista, un numero— no
  # revienta: `to_string/1` sobre un mapa es un `Protocol.UndefinedError`, y un
  # modulo que responde a "que te paso aqui" con un stack trace no ayuda a
  # nadie.
  defp atom_de(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: value

  defp atom_de(value) when is_binary(value),
    do: Enum.find(@usage_types ++ @capability_types, &(Atom.to_string(&1) == value))

  defp atom_de(_otro), do: nil

  defp inspeccion(value) when is_binary(value), do: value
  defp inspeccion(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp inspeccion(value), do: inspect(value)

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
  Returns the full path to the **draft** model file on disk.

  The draft is the speculative-decoding companion declared as `[model.X.draft]`.
  It is a real dependency and not a nicety: `model_args` carries
  `--model-draft` with this path, and llama-server exits with
  `failed to open GGUF file` when the file is not there. So a model with a
  draft cannot start without it, and anything that installs or removes models
  has to know about it.

  Returns `nil` when the model declares no draft —the common case. A `:local`
  draft returns its own path, exactly as `file_path/1` does for a `:local`
  `:source`: whoever declared it put the file there, and `models remove` takes
  it away like the main one.
  """
  @spec draft_path(t()) :: binary() | nil
  def draft_path(%__MODULE__{type: :remote}), do: nil

  def draft_path(%__MODULE__{draft: nil}), do: nil

  # Un draft `:local` devuelve su ruta, igual que `file_path/1` hace con un
  # `:source` local: quien lo declaro puso el fichero ahi, y `models remove`
  # lo borra igual que el principal. La excepcion del `..` es la misma.
  def draft_path(%__MODULE__{draft: %Candil.Source{kind: :local, path: path}})
      when is_binary(path) do
    if path_traversal?(path), do: nil, else: Path.expand(path)
  end

  def draft_path(%__MODULE__{draft: %Candil.Source{} = source}) do
    dest = Source.dest_path(source)
    if dest && path_traversal?(dest), do: nil, else: dest
  end

  def draft_path(_), do: nil

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
      |> validate_capabilities(model)

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
      else: [
        "invalid usage types: #{inspect(invalid)} (endpoints: #{inspect(@usage_types)})" | errors
      ]
  end

  defp validate_usage(errors, _), do: ["usage must be a list" | errors]

  # Las capacidades se comprueban en el mismo sitio y por la misma razon: un
  # `usage` con un valor inventado es un catalogo que miente, y una capacidad
  # inventada tambien. Lo que no se hace es aceptarlas por simpatia: el error
  # sale en `Store.register_model`, que es donde ya salia el de `usage`.
  defp validate_capabilities(errors, %{capabilities: capabilities}) when is_list(capabilities) do
    invalid = Enum.reject(capabilities, &(&1 in @capability_types))

    if invalid == [],
      do: errors,
      else: [
        "invalid capabilities: #{inspect(invalid)} (known: #{inspect(@capability_types)})"
        | errors
      ]
  end

  defp validate_capabilities(errors, _), do: ["capabilities must be a list" | errors]
end
