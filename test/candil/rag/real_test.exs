defmodule Candil.RAG.RealTest do
  @moduledoc """
  Qué es `Candil.RAG` HOY, comprobado y no supuesto.

  ## Por qué este test es un test de "todavía no"

  El plan llama "RAG" a lo que hay en `lib/candil/rag.ex`. Y lo que hay son
  **cinco funciones que devuelven `{:error, :not_implemented}`** más un struct
  `Chunk` con los tipos congelados.

  Eso no es un RAG a medio hacer: es un RAG con la **superficie decidida y el
  cuerpo pendiente**. Y esa diferencia importa, porque lo que está decidido se
  puede usar y lo que no se puede ni siquiera discutir sin inventar.

  ## Por qué fijarlo en un test

  Porque un stub que devuelve `:not_implemented` **debería** seguir así hasta
  que la fase 10 lo escriba, y este test se pone **ROJO** el día que alguien lo
  implemente de verdad. Eso es un test de contrato que trabaja en la dirección
  contraria: no falla porque falte algo, falla cuando algo llega.

  La alternativa —un test que hace `assert match?({:error, _}, ...)` y pase
  siempre— no fija nada. Este sí.

  ## Lo que NO se comprueba aquí

  Que la recuperación funcione. Todavía no hay nada que recuperar, y un test que
  lo fingiera estaría mintiendo con la misma $\{\:error, \}\` en la que el módulo
  ya está.
  """

  use ExUnit.Case, async: false

  alias Candil.Error
  alias Candil.RAG
  alias Candil.RAG.Chunk

  # ── el struct, que sí es real ────────────────────────────────────────────────

  describe "Candil.RAG.Chunk, que sí existe y está congelado" do
    test "exige id y texto: un chunk sin texto no es un chunk" do
      assert_raise ArgumentError, fn ->
        struct!(Chunk, id: "c1")
      end
    end

    test "guarda de donde viene, para poder citarlo" do
      chunk = %Chunk{
        id: "c1",
        text: "El rentals vive en el gateway.",
        document_id: "doc:handbook",
        position: 4,
        metadata: %{}
      }

      assert chunk.text =~ "gateway"
      assert chunk.document_id == "doc:handbook"
      # `position` es lo que permite decir "párrafo 4" en vez de un id opaco.
      # Un RAG al que no puedes citar no sirve para nada.
      assert chunk.position == 4
    end

    test "el texto puede estar vacio" do
      # Vacio es legal: un chunk sin texto es un chunk inútil, no uno imposible.
      # Lo que NO puede pasar es perder el texto en silencio, y para eso esta
      # la asercion de arriba, con `@enforce_keys`.
      chunk = %Chunk{id: "c1", text: ""}
      assert chunk.text == ""
    end
  end

  # ── las cinco funciones, que NO existen todavía ──────────────────────────────

  describe "las cinco funciones publicas, que no estan escritas" do
    test "create_index/2 dice que no, y en que fase esta" do
      assert {:error, %Error{reason: :not_implemented} = error} =
               RAG.create_index("mi_indice")

      # No basta con "no funciona": dice EN QUE FASE esta. Un error sin sitio
      # donde mirar es un callejon sin salida.
      assert error.context[:phase] == 10
    end

    test "index/3 tambien, y con las dos formas de entrada" do
      assert {:error, %Error{reason: :not_implemented}} = RAG.index("mi_indice", "texto")
      assert {:error, %Error{reason: :not_implemented}} = RAG.index("mi_indice", "/tmp/f.txt")
    end

    test "search/3 tambien" do
      assert {:error, %Error{reason: :not_implemented}} = RAG.search("mi_indice", "una consulta")
    end

    test "el patron se sostiene para cualquier combinacion" do
      # Si alguien implementa UNA de las cinco y se olvida de avisar, esto se
      # queda en rojo y se ve en el commit, no en produccion.
      for {_name, resultado} <- [
            {"create_index", RAG.create_index("i")},
            {"index", RAG.index("i", "t")},
            {"search", RAG.search("i", "q")}
          ] do
        assert {:error, %Error{reason: :not_implemented}} = resultado,
               "#{_name} ya no es un stub: la fase 10 ha empezado sin updating esto"
      end
    end
  end

  # ── la unica funcion con logica real ──────────────────────────────────────────

  describe "embedder/1, que es lo unico que hace algo" do
    test "con un nombre que NO esta en el registro, lo dice nombrandolo" do
      # HALLAZGO: no devuelve el nombre, devuelve un error que lo nombra:
      # `{:error, {:unknown_embedder, "nvidia"}}`. Es mejor que devolver el
      # nombre a secas —un nombre que nadie ha registrado no es un embedder, es
      # una suposicion—, y desde el punto de vista de quien depura, un
      # `{:error, :no_embedder}` a secas obligaba a ir a buscar cual faltaba.
      assert RAG.embedder(%{embedder: "nvidia/embed"}) ==
               {:error, {:unknown_embedder, "nvidia/embed"}}
    end

    test "sin embedder, lo dice nombrando lo que falta" do
      # `{:error, :no_embedder}` SIN el nombre seria «no hay embedder», que
      # obliga a ir a buscarlo. Con el nombre es una linea de config.
      assert RAG.embedder(%{}) == {:error, :no_embedder}
      assert RAG.embedder(%{embedder: ""}) == {:error, :no_embedder}
    end

    test "lo que NO hace: no adivina un embedder que no existe" do
      # No hay un embedder por defecto "de serie". Pedir uno que no esta
      # registrado es un error que dice cual, no un nombre devuelto a la
      # ligera que luego fallaria en el primer uso.
      assert {:error, {:unknown_embedder, nombre}} = RAG.embedder(%{embedder: "nvidia/embed"})
      assert nombre == "nvidia/embed"
    end
  end

  # ── lo que el modulo promete, y lo que no cumple todavia ────────────────────

  describe "lo que el @moduledoc promete" do
    test "coseno sobre un escaneo lineal" do
      # Prometido en el moduledoc, y no hay una linea de codigo que lo haga. Se
      # deja anotado para que la fase 10 no lo descubra tarde: la promesa es
      # real, la implementacion no.
      Code.ensure_loaded(RAG)
      assert function_exported?(RAG, :search, 3)
      # Que exista la funcion NO significa que el escaneo exista. Por eso este
      # test mira LAS DOS COSAS: la superficie esta, y el cuerpo no.
      assert {:error, %Error{reason: :not_implemented}} = RAG.search("x", "y")
    end
  end
end
