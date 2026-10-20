defmodule Candil.Scheduler.CableadoTest do
  @moduledoc """
  Pruebas de que el scheduler está cableado de verdad: `ensure_engine_running/2`
  consulta a `Scheduler.plan/1`.

  Sin estas, borrar el cableado deja la suite verde (D-10).

  El binario y el modelo **no existen a propósito**: el rechazo de `:no_room`
  ocurre antes de tocar el fichero. Si alguien cambia el orden y el arranque
  falla por «binary not found», la aserción de `:no_room` se pone roja —que es
  lo que se quiere.
  """

  use ExUnit.Case, async: false

  alias Candil.{Model, Store}

  setup do
    Candil.StoreCase.empty_store()
    on_exit(fn -> Candil.StoreCase.empty_store() end)
    :ok
  end

  test "un modelo que no cabe devuelve :no_room (cableado)" do
    engine = %Candil.Engine{
      alias: :llama_cpp,
      binary: "/nonexistent/llama-server",
      host: "127.0.0.1",
      port: 9991
    }

    Candil.Store.register_engine(engine)

    model = %Model{
      alias: :huge_test,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      vram_mb: 999_999,
      usage: [:chat],
      model_dir: "/nonexistent",
      filename: "huge.gguf"
    }

    Store.register_model(model)

    assert {:error, :no_room} = Candil.ensure_engine_running(:huge_test, [])
  end
end
