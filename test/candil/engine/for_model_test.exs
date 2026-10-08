defmodule Candil.Engine.ForModelTest do
  @moduledoc """
  The engine that starts a model has to be the one in the catalogue.

  A `%Engine{alias: :llama_cpp}` carries the alias and nothing else: no
  `binary`, no `install`, no `api_key`, no `start_args`, and `port: 8080`
  because that is what the defstruct says. `EnginePool.put/5` starts a
  GenServer, and a GenServer on 8080 starts perfectly — so `candil run` printed
  `arrancado en :9999`, exited 0, and started no model at all. The user found
  it watching VRAM with btop: a 27B that never moved the 47 MB baseline.

  Every smoke test before that checked exit codes. This checks the thing that
  was actually wrong.
  """
  use Candil.StoreCase

  alias Candil.{Engine, Model, Store}

  setup do
    # `async: false` y no `true`: el Store es GLOBAL, y `cli_test.exs` registra
    # un engine llamado tambien `:llama_cpp`. Con los dos ficheros en paralelo,
    # el test que espera "no hay ningun engine en el catalogo" se encuentra el
    # de otro y falla sin que nadie haya escrito mal una linea. Un Store
    # compartido obliga a no compartir los alias, y un alias compartido obliga
    # a no compartir el fichero.
    on_exit(fn -> Store.deregister_engine(:llama_cpp) end)
    :ok
  end

  test "devuelve el engine del catalogo con sus valores, no uno de默认值" do
    store_engine(%Engine{
      alias: :llama_cpp,
      binary: "/opt/llm/bin/llama-server",
      host: "127.0.0.1",
      base_port: 10_000,
      port: 10_000,
      api_key: "secreto",
      start_args: ["--flash-attn"]
    })

    assert {:ok, engine} = Engine.for_model(model(), 9999)

    assert engine.binary == "/opt/llm/bin/llama-server"
    assert engine.api_key == "secreto"
    assert engine.start_args == ["--flash-attn"]
    assert engine.alias == :llama_cpp
  end

  test "el puerto del modelo se pone en el engine, que es donde lo mira el Server" do
    store_engine(%Engine{alias: :llama_cpp, binary: "/opt/llm/llama-server", port: 10_000})

    assert {:ok, engine} = Engine.for_model(model(), 9999)
    # `Candil.Engine.Server` construye `base_url` con `engine.port`. Con el
    # 8080 por defecto la sonda de salud mira el sitio equivocado y el modelo
    # no se considera sano nunca.
    assert engine.port == 9999
  end

  test "un modelo sin engine no inventa uno" do
    assert {:error, :not_found} =
             Engine.for_model(%Model{alias: :x, engine: nil, type: :local}, 9999)
  end

  test "un engine que no esta en el catalogo es un error, no un struct vacio" do
    assert {:error, :not_found} = Engine.for_model(model(), 9999)
  end

  defp store_engine(engine), do: Store.register_engine(engine)

  defp model, do: %Model{alias: :coder, engine: :llama_cpp, type: :local}
end
