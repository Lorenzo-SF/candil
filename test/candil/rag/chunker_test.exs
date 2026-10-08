defmodule Candil.RAG.ChunkerTest do
  @moduledoc """
  Cómo se corta un documento, y sobre todo: **quién decide**.

  ## El problema que esto arregla

  El chunking es la primera decision que RAG toma sobre tu texto, y afecta a
  todo lo que viene despues: lo que se recupera, lo que se cita y si el modelo
  encuentra la frase que buscaba.

  Si el corte esta escrito en el modulo, cambiarlo es recompilar Candil. Y si
  el corte es un parametro suelto, es un dato sin contrato.

  Aqui es las dos cosas: **el `Chunker` es codigo, y la eleccion es un valor.**

  ## Los tres modos, y por que son tres y no uno

  - `:fixed` — cada N tokens. Mecanico, predecible, y parte palabras por la
    mitad. Es el que hay que usar cuando nada mas serve, no el que hay que
    dejar por defecto.
  - `:sentence` — por frases. **El default**, porque el corte respeta el
    significado: un fragmento que se acaba a mitad de oracion no se puede citar
    ni entender.
  - `:paragraph` — por parrafos, para texto que ya viene con esa estructura.

  Los tres son **modos del mismo chunker**, no tres chunkers. Anadir un cuarto no
  toca Candil.
  """

  use ExUnit.Case, async: false

  alias Candil.RAG.Chunk
  alias Candil.RAG.Chunker

  # Un texto con frases de longitud conocida, para poder medir sin depender de
  # como estime Candil los tokens.
  @tres "Uno. Dos. Tres. Cuatro. Cinco."

  # ── el contrato ─────────────────────────────────────────────────────────────

  describe "el contrato" do
    test "cortar devuelve chunks, y cada chunk cumple el tipo congelado" do
      chunks = Chunker.chunk("Hola mundo. Esto es un texto.", strategy: :sentence)

      assert is_list(chunks)
      assert chunks != []

      for chunk <- chunks do
        assert %Chunk{} = chunk
        assert is_binary(chunk.id)
        assert is_binary(chunk.text)
      end
    end

    test "cada chunk sabe de que documento vino y en que posicion esta" do
      chunks = Chunker.chunk(@tres, document_id: "doc:uno", strategy: :sentence)

      for {chunk, i} <- Enum.with_index(chunks) do
        assert chunk.document_id == "doc:uno"
        # Sin `position` no se puede decir "párrafo 4", y un RAG al que no se
        # puede citar no sirve para comprobar una respuesta.
        assert chunk.position == i
      end
    end

    test "los ids son distintos, porque son la clave del indice" do
      chunks = Chunker.chunk(String.duplicate(@tres <> " ", 3), strategy: :sentence)

      ids = Enum.map(chunks, & &1.id)
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  # ── los tres modos ──────────────────────────────────────────────────────────

  describe "sentence, el default" do
    test "parte por frases y no parte ninguna" do
      texto = "Primera frase. Segunda frase. Tercera frase."
      chunks = Chunker.chunk(texto, strategy: :sentence)

      for chunk <- chunks do
        refute chunk.text =~ "Primera frase. Seg"
        # Ningun chunk acaba a mitad de una frase.
        assert String.ends_with?(String.trim(chunk.text), ".")
      end
    end

    test "es el default cuando no se dice nada" do
      a = Chunker.chunk(@tres)
      b = Chunker.chunk(@tres, strategy: :sentence)

      assert Enum.map(a, & &1.text) == Enum.map(b, & &1.text)
    end
  end

  describe "fixed" do
    test "parte por tamano, aunque parta palabras" do
      texto = String.duplicate("palabra ", 40)
      chunks = Chunker.chunk(texto, strategy: :fixed, size: 10)

      assert length(chunks) > 1
      # Y eso esta bien: `fixed` es el modo mecanico, y su valor es que NUNCA
      # parte palabras ni pierde contexto. El que lo hace es `:sentence`.
      assert Enum.all?(chunks, &is_binary(&1.text))
    end
  end

  describe "paragraph" do
    test "respeta los saltos de parrafo" do
      texto = "Uno.\n\nDos.\n\nTres."
      chunks = Chunker.chunk(texto, strategy: :paragraph)

      assert length(chunks) == 3
      assert Enum.all?(chunks, &(&1.text =~ ~r/Uno|Dos|Tres/))
    end
  end

  # ── lo que NO hace ──────────────────────────────────────────────────────────

  describe "lo que no hace" do
    test "un texto vacio devuelve lista vacia, no un error" do
      assert Chunker.chunk("", strategy: :sentence) == []
    end

    test "un texto sin puntuacion no se pierde: sale entero" do
      # Es el caso del chatbot de biblioteca: una pregunta sin punto final. Si
      # el chunker exigiera puntuacion, ese texto se descartaria entero, y con
      # el se pierde la pregunta.
      texto = "donde esta el formulario de renovacion de prestamos"
      chunks = Chunker.chunk(texto, strategy: :sentence)

      assert chunks != []
      assert Enum.join(Enum.map(chunks, & &1.text), " ") =~ "renovacion"
    end

    test "una estrategia desconocida es un error que la NOMBRA, no un :miss" do
      # `{:error, :no_such_strategy}` obliga a ir a mirar la lista. Un `:error`
      # a secas deja al usuario leyendo el codigo para saber que valores hay.
      assert {:error, {:unknown_strategy, :inventado}} =
               Chunker.chunk("texto", strategy: :inventado)
    end

    test "y la lista de estrategias sale del modulo, no de una constante" do
      # Un `str_to_atom` sobre lo que pone el usuario crearia atomos; una lista
      # escrita en un sitio y leida en otro se queda vieja. Sale de aqui.
      for strategy <- Chunker.strategies() do
        assert Chunker.chunk("Uno. Dos.", strategy: strategy) != []
      end
    end
  end

  describe "un chunker de un tercero, SIN tocar Candil" do
    defmodule PorPreguntas do
      @moduledoc "Un chunker que sabe de RAG: cada pregunta con su respuesta."
      @behaviour Candil.RAG.Chunker

      @impl true
      def chunk(text, opts), do: Candil.RAG.Chunker.chunk(text, opts)

      @impl true
      def split(text, _opts) do
        ~r/\n\s*(?=[A-ZÁÉÍÓÚÑ¿])/u |> then(&String.split(text, &1))
      end
    end

    test "se registra y a partir de ahi `chunk/2` lo usa" do
      on_exit(fn ->
        if :ets.whereis(:candil_rag_chunker) != :undefined,
          do: :ets.delete(:candil_rag_chunker, :preguntas)
      end)

      # Este es EL test del modulo. Si pasa, un tercero corta como quiera.
      assert :ok = Chunker.register(:preguntas, PorPreguntas)

      chunks = Chunker.chunk("Uno\nDos\nTres", strategy: :preguntas)
      assert length(chunks) == 3
      assert Enum.map(chunks, & &1.text) == ["Uno", "Dos", "Tres"]
    end

    test "y una estrategia registrada cuenta como valida" do
      on_exit(fn ->
        if :ets.whereis(:candil_rag_chunker) != :undefined,
          do: :ets.delete(:candil_rag_chunker, :preguntas)
      end)

      Chunker.register(:preguntas, PorPreguntas)

      assert Chunker.registered?(:preguntas)
      # `strategies/0` son las de Candil; las de terceros no se inventan.
      refute :preguntas in Chunker.strategies()
    end
  end
end
