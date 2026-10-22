defmodule Candil.Router.EmbedderHonestTest do
  @moduledoc """
  La capa `:embedding` del router solo puede ejecutarse si hay un embedder
  **que pueda atender una petición** ✓.

  ## El fallo que caza este test

  `embedder_available?/0` preguntaba si el Store tiene un modelo con
  `usage: [:embeddings]` ✓ — y el Store registra lo que **declara** el
  catálogo ✓, no lo que está en disco ✓.

  Medido el 2026-10-22: en el catálogo de esta máquina hay **tres** modelos con
  `usage: [:embeddings]` (`embed` ✓, `vector` ✓, `ranker` ✓) y **ninguno tiene
  fichero** ✓ — están retirados en ropero ✓. La capa se ejecutaba ✓, no
  producía nada ✓, y el `trail` decía `{:embedding, 3, 3}` ✓: una capa que se
  marca como ejecutada y no decide ✓.

  Y el daño no es teórico: el `trail` dice qué capas exitieron ✓, y quien lo
  lee no puede distinguir «esta capa decidió» de «esta capa se pasó por
  encima» ✓. Sin embedder, la capa tiene que **saltarse** ✓ — y el skip es un
  hecho de la decisión ✓, no un detalle interno ✓.
  """

  use ExUnit.Case, async: false

  alias Candil.{Engine, Model, Router, Store}
  alias Candil.Router.{Cache, Consumer}

  @code [%{role: "user", content: "refactoriza este modulo de Elixir y arregla el bug"}]

  setup do
    Cache.flush()
    Consumer.unpin(:test_consumer)

    Candil.StoreCase.empty_store()
    on_exit(fn -> Candil.StoreCase.empty_store() end)

    :ok =
      Store.register_engine(%Engine{
        alias: :llama_cpp,
        binary: "llama-server"
      })

    dir = Path.join(System.tmp_dir!(), "candil-embed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    register(:coder, [:chat, :code], dir, false)
    register(:verifier, [:chat, :reasoning], dir, false)
    register(:embed, [:embeddings], dir, false)

    %{dir: dir}
  end

  defp register(alias, usage, dir, with_file?) do
    {endpoints, capacidades, _invalidos} = Model.split_usage(usage)
    filename = "#{alias}.gguf"

    if with_file? do
      File.write!(Path.join(dir, filename), "no es un gguf, pero existe")
    end

    model = %Model{
      alias: alias,
      type: :local,
      engine: :llama_cpp,
      usage: endpoints,
      capabilities: capacidades,
      model_dir: dir,
      filename: filename
    }

    :ok = Store.register_model(model)
  end

  test "un embedder SIN fichero: la capa se salta y la decision lo dice", %{dir: dir} do
    assert {:ok, decision} =
             Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

    # La capa se salta ✓ → la decision dice que se decidio con menos
    # informacion ✓. Y `confidence_reasons` lo nombra ✓.
    assert decision.confidence == :reduced
    assert :embedding in decision.confidence_reasons
  end

  test "un embedder CON fichero: la capa se ejecuta", %{dir: dir} do
    File.write!(Path.join(dir, "embed.gguf"), "no es un gguf, pero existe")

    assert {:ok, decision} =
             Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

    # Con el embedder en disco, la capa NO se salta ✓ → la decision no lleva
    # la marca de degradacion ✓.
    refute :embedding in decision.confidence_reasons
    assert decision.confidence == :full
  end

  test "un embedder remoto sirve aunque no tenga fichero" do
    Store.deregister_model(:embed)

    remote = %Model{
      alias: :embed_remoto,
      type: :remote,
      provider: :openai,
      name: "text-embedding-3-small",
      usage: [:embeddings],
      model_dir: nil,
      filename: nil
    }

    :ok = Store.register_model(remote)

    assert {:ok, decision} =
             Router.DecisionEngine.decide(@code, [:coder, :verifier], consumer: :test_consumer)

    # Un remoto no tiene `.gguf` detras ✓ pero atiende peticiones ✓ → la capa
    # no se salta ✓.
    refute :embedding in decision.confidence_reasons
  end
end
