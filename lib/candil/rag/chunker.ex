defmodule Candil.RAG.Chunker do
  @moduledoc """
  Cómo se corta un documento. La primera decisión que RAG toma sobre tu texto.

  ## Por qué es un behaviour y no una función

  El corte afecta a todo lo que viene después: lo que se recupera, lo que se
  cita y si el modelo encuentra la frase que buscaba. Y **cambiar de corte es
  normal** —un manual técnico va por secciones, un FAQ va por pregunta— así que
  no puede estar escrito dentro del módulo que corta.

  Aquí es las dos cosas:

  - **El chunker es código.** Una función con una forma, que un tercero
    implementa si sabe algo que Candil no.
  - **La elección es un valor.** `:sentence`, `:fixed`, `:paragraph`, en el TOML.

  ## Los tres modos, y por qué tres y no uno

  - `:sentence` — **el default**, porque el corte respeta el significado. Un
    fragmento que acaba a mitad de una frase no se puede citar ni entender.
  - `:fixed` — cada N palabras. Mecánico, predecible, y parte palabras por la
    mitad. Es el que hay que usar cuando nada más sirve, no el que hay que dejar
    por defecto.
  - `:paragraph` — por párrafos, para texto que ya viene con esa estructura.

  Los tres son **modos del mismo chunker**, no tres chunkers. Añadir un cuarto no
  toca Candil: se registra con `register/2`.

  ## Lo que un chunk SIEMPRE lleva

  `:document_id` y `:position`, aunque no se los pidas. Sin `position` no se
  puede decir «párrafo 4», y un RAG al que no se puede citar no sirve para
  comprobar una respuesta.

  ## Lo que NO hace

  **No descarta texto por no tener puntuación.** Un chatbot de biblioteca hace
  preguntas sin punto final, y un chunker que exigiera puntuación perdería la
  pregunta entera. Lo que no se puede partir por frases se devuelve entero.
  """

  alias Candil.RAG.Chunk

  @type strategy :: :sentence | :fixed | :paragraph

  @type option ::
          {:strategy, strategy()}
          | {:size, pos_integer()}
          | {:overlap, non_neg_integer()}
          | {:document_id, binary()}

  @doc """
  Corta un texto en chunks.

  Devuelve `{:ok, chunks}` ✓ y `{:error, {:unknown_strategy, s}}` ✓ si la
  estrategia no existe ✓. **Un `{:ok, []}`** es un texto que no ha dado
  chunks ✓ —no un fallo ✓— y por eso es un `ok` y no un error ✓.
  """
  @callback chunk(text :: binary(), opts :: [option()]) ::
              {:ok, [Chunk.t()]} | {:error, {:unknown_strategy, term()}}

  @doc false
  @callback split(text :: binary(), opts :: [option()]) :: [binary()]

  @strategies [:sentence, :fixed, :paragraph]

  # El corte por defecto NO cambia sin motivo escrito, porque cambia lo que se
  # recupera y lo que se cita.
  @default_strategy :sentence

  @table __MODULE__

  @doc false
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _ -> :ok
    end

    :ok
  end

  @doc """
  Registra un chunker para una estrategia nueva.

  Es lo que hace que esto sea un framework y no un programa con una funcion: un
  tercero que sabe cortar por secciones, o por tiempo de audio, o por arbol
  sintactico, lo registra y `chunk/2` lo usa sin que Candil se entere.
  """
  @spec register(strategy(), module()) :: :ok | {:error, term()}
  def register(strategy, module) when is_atom(strategy) and is_atom(module) do
    ensure_table()
    :ets.insert(@table, {strategy, module})
    :ok
  end

  @doc "Si hay un chunker registrado para esa estrategia."
  @spec registered?(strategy()) :: boolean()
  def registered?(strategy) do
    ensure_table()
    :ets.member(@table, strategy)
  end

  @doc """
  Corta `text` con la estrategia de `opts`.

  ## Ejemplos

      iex> {:ok, chunks} = Chunker.chunk("Uno. Dos.")
      iex> length(chunks)
      1

      iex> {:ok, chunks} = Chunker.chunk("Uno. Dos. Tres.", strategy: :paragraph)
      iex> length(chunks)
      1
  """
  @spec chunk(binary(), [option()]) ::
          {:ok, [Chunk.t()]} | {:error, {:unknown_strategy, term()}}
  def chunk(text, opts \\ [])

  def chunk("", _opts), do: {:ok, []}

  def chunk(text, opts) when is_binary(text) do
    strategy = Keyword.get(opts, :strategy, @default_strategy)
    document_id = Keyword.get(opts, :document_id)

    case Enum.find(@strategies, &(strategy == &1)) do
      nil ->
        if registered?(strategy),
          do: do_chunk(text, opts, strategy, document_id),
          else: {:error, {:unknown_strategy, strategy}}

      _known ->
        do_chunk(text, opts, strategy, document_id)
    end
  end

  defp do_chunk(text, opts, strategy, document_id) do
    splitter = splitter_for(strategy)

    chunks =
      text
      |> splitter.split(opts)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index()
      |> Enum.map(fn {part, position} ->
        %Chunk{
          id: chunk_id(document_id, position, part),
          text: part,
          document_id: document_id,
          position: position
        }
      end)

    {:ok, chunks}
  end

  # El id de un chunk tiene que ser **estable**: el mismo documento, en la
  # misma posicion y con el mismo texto, es **el mismo chunk** ✓. Con el id
  # por posicion (`"doc:0"`), reindexar un documento cuyo inicio cambio
  # reescribe todos los ids ✓, y lo que estaba ahi se queda viejo ✓.
  #
  # El hash lleva el **texto** dentro ✓ a proposito: si el texto cambia, el
  # chunk es otro chunk ✓, y el indice viejo tiene que quedarse sin ese id ✓.
  @doc false
  @spec chunk_id(binary() | nil, non_neg_integer(), binary()) :: binary()
  def chunk_id(document_id, position, text) do
    payload = "#{document_id || "doc"}:#{position}:#{text}"

    payload
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp splitter_for(strategy) do
    ensure_table()

    case :ets.lookup(@table, strategy) do
      [{^strategy, module}] -> module
      [] -> module_for(strategy)
    end
  end

  defp module_for(strategy) do
    case strategy do
      :sentence -> __MODULE__.Sentence
      :paragraph -> __MODULE__.Paragraph
      :fixed -> __MODULE__.Fixed
    end
  end

  @doc "Las estrategias que trae Candil."
  @spec strategies() :: [strategy()]
  def strategies, do: @strategies

  @doc "La estrategia por defecto."
  @spec strategy() :: strategy()
  def strategy, do: @default_strategy

  @doc """
  La estrategia por defecto.

  Es un alias de `strategy/0` ✓, que es el nombre canonico ✓: `strategy/0` es
  el que dice el contrato ✓ y `default_strategy/0` el que se usaba antes ✓.
  Los dos devuelven lo mismo ✓, y asi nadie rompe por el nombre ✓.
  """
  @spec default_strategy() :: strategy()
  def default_strategy, do: strategy()

  defmodule Sentence do
    @moduledoc "Por frases. El que respeta el significado, y el default."
    @behaviour Candil.RAG.Chunker

    @impl true
    def chunk(text, opts), do: Candil.RAG.Chunker.chunk(text, opts)

    @impl true
    def split(text, _opts), do: String.split(text, ~r/(?<=[.!?])\s+/u)
  end

  defmodule Paragraph do
    @moduledoc "Por parrafos, para texto que ya viene con esa estructura."
    @behaviour Candil.RAG.Chunker

    @impl true
    def chunk(text, opts), do: Candil.RAG.Chunker.chunk(text, opts)

    @impl true
    def split(text, _opts), do: String.split(text, ~r/\n\s*\n/u)
  end

  defmodule Fixed do
    @moduledoc """
    Por tamaño. Mecánico y predecible, y **parte palabras a proposito**.

    Ese es el pacto: `fixed` nunca pierde contexto y nunca inventa un corte que
    no sea un tamaño. El que quiere significado usa `sentence`.
    """
    @behaviour Candil.RAG.Chunker

    @default_size 200

    @impl true
    def chunk(text, opts), do: Candil.RAG.Chunker.chunk(text, opts)

    @impl true
    def split(text, opts) do
      size = Keyword.get(opts, :size, @default_size)
      overlap = Keyword.get(opts, :overlap, 0)

      if is_integer(size) and size > 0 do
        text
        |> String.split(~r/\s+/u, trim: true)
        |> window(size, overlap)
        |> Enum.map(&Enum.join/1)
      else
        [text]
      end
    end

    # El solape se hace sobre PALABRAS, no sobre caracteres: cortar por mitad de
    # una palabra ya es el pacto de `:fixed`, pero cortar sin dejar nada en
    # medio hace que un chunk no tenga ni la palabra que empieza ni la que acaba.
    defp window(words, size, overlap) do
      step = max(size - overlap, 1)
      window(words, size, step, [])
    end

    defp window([], _size, _step, acc), do: Enum.reverse(acc)

    defp window(words, size, _step, acc) when length(words) <= size,
      do: Enum.reverse([words | acc])

    defp window(words, size, step, acc) do
      {chunk, rest} = Enum.split(words, size)
      window(rest, size, step, [chunk | acc])
    end
  end
end
