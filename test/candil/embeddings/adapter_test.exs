defmodule Candil.Embeddings.AdapterTest do
  @moduledoc """
  Qué embedder se usa, y quién lo decide.

  ## El problema

  `Candil.Embeddings.embed/3` decidía el backend con un `case` sobre **strings**:

  ```elixir
  provider = Keyword.get(opts, :provider, "local")
  case provider do
    "ollama" -> ...
    _ -> ...
  end
  ```

  Dos cosas malas a la vez:

  1. **Un typo no falla donde debe.** Si pones `"local "` con un espacio, no dice
     «no conozco ese provider»: se cae en la rama por defecto y **habla con el
     embedder equivocado creyendo que es el correcto.**
  2. **Añadir un embedder es tocar Candil.**

  Es el mismo patrón que `Provider` antes de su behaviour, donde el tipo vivía
  en dos listas —una que valida y otra que construye— y por eso un olvido
  producía «unknown type» en un sitio y un `FunctionClauseError` con el token ya
  gastado en otro.

  ## Lo que hace este behaviour

  Poner el embedder en un **registro**, con la elección siendo un **valor**.
  """

  use Candil.StoreCase, async: false

  alias Candil.Embeddings.Adapter

  defmodule Hashes do
    @moduledoc """
    Un embedder de mentira, pero con las DOS características que importan de uno
    de verdad: **devuelve vectores de la dimensión que le digan** y **es
    determinista**, así que un mismo texto da el mismo vector.
    """
    @behaviour Adapter

    @impl true
    def embed(texts, opts) when is_list(texts) do
      dim = Keyword.get(opts, :dimension, 3)
      {:ok, Enum.map(texts, &hash_vector(&1, dim))}
    end

    @impl true
    def dimension(opts \\ []), do: Keyword.get(opts, :dimension, 3)

    @impl true
    def supports?(_modality), do: true

    # Sin normalizar ahí: la normalización es de quien indexa, no del embedder,
    # y hacerla en los dos sitios es como la distancia coseno acaba siendo
    # distinta de la que uno cree.
    defp hash_vector(text, dim) do
      for i <- 0..(dim - 1), do: rem(:erlang.phash2({text, i}), 1000) / 1000
    end
  end

  setup do
    on_exit(fn ->
      if :ets.whereis(:candil_embeddings_adapters) != :undefined,
        do: :ets.delete(:candil_embeddings_adapters, :hashes)
    end)

    :ok
  end

  defp with_adapter do
    :ok = Adapter.register(:hashes, Hashes)
    :ok
  end

  # ── el contrato ─────────────────────────────────────────────────────────────

  describe "el contrato" do
    test "un embedder registrado devuelve un vector por texto" do
      with_adapter()

      assert {:ok, vectors} = Adapter.embed(["uno", "dos"], provider: :hashes, dimension: 4)
      assert length(vectors) == 2
      assert Enum.all?(vectors, &(length(&1) == 4))
    end

    test "es determinista: el mismo texto da el mismo vector" do
      with_adapter()

      assert {:ok, [a]} = Adapter.embed(["hola"], provider: :hashes, dimension: 8)
      assert {:ok, [b]} = Adapter.embed(["hola"], provider: :hashes, dimension: 8)
      assert a == b
    end

    test "y texto distinto da vector distinto" do
      with_adapter()

      assert {:ok, [a]} = Adapter.embed(["hola"], provider: :hashes, dimension: 8)
      assert {:ok, [b]} = Adapter.embed(["adios"], provider: :hashes, dimension: 8)
      refute a == b
    end
  end

  # ── lo que se gana ──────────────────────────────────────────────────────────

  describe "un embedder de un tercero, SIN tocar Candil" do
    test "se registra y a partir de ahi se usa" do
      with_adapter()

      # Este es EL test. Si pasa, Candil deja elegir embedder sin recompilarlo.
      assert {:ok, [vector]} = Adapter.embed(["texto"], provider: :hashes, dimension: 3)
      assert length(vector) == 3
    end

    test "cada embedder decide su propia dimension" do
      with_adapter()

      assert {:ok, [v3]} = Adapter.embed(["x"], provider: :hashes, dimension: 3)
      assert {:ok, [v16]} = Adapter.embed(["x"], provider: :hashes, dimension: 16)
      assert length(v3) == 3
      assert length(v16) == 16
    end

    test "un embedder que no esta registrado lo dice por su NOMBRE" do
      # Y no `String.to_atom` del nombre: eso crea un atomo por cada typo del
      # toml, que es denegación de servicio con un fichero de configuración.
      assert {:error, {:unknown_embedder, :no_existe}} =
               Adapter.embed(["x"], provider: :no_existe)
    end

    test "y la lista sale del registro, no de una constante" do
      with_adapter()
      # `Adapter.available()` devuelve una lista de nombres registrados. La
      # comparacion es `Enum.member?/2` porque `assert x in list` dentro de un
      # test de ExUnit se resuelve como llamada de funcion en algunos casos y
      # falla con un ArgumentError que no dice nada de embedders.
      assert Enum.member?(Adapter.available(), :hashes)
    end
  end

  # ── la decisión ─────────────────────────────────────────────────────────────

  describe "sin embedder por defecto" do
    test "no hay ninguno, y eso es una decisión" do
      with_adapter()

      # Decidirlo es un acto: un embedder por defecto global decide, para todo
      # el mundo, en qué se calculan las distancias entre vectores. No es un
      # detalle, y tomarlo por omisión es tomarlo sin querer — que es
      # justo lo que hacía el `case` de `"local"`.
      assert Adapter.default_embedder() == nil
      assert Adapter.adapter_for(nil) == :error

      # Y quien no diga nada lo lee claro, en vez de hablar con uno al azar.
      assert {:error, {:unknown_embedder, nil}} = Adapter.embed(["texto"])
    end
  end
end
