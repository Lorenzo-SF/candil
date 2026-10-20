defmodule Candil.Scheduler.CableadoTest do
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
      binary: "/home/lorenzo/.local/bin/llama-server",
      host: "127.0.0.1",
      port: 9991
    }

    Candil.Store.register_engine(engine)

    model = %Model{
      alias: :huge_test,
      type: :local,
      engine: :llama_cpp,
      context_size: 32_768,
      vram_mb: 999_999,
      usage: [:chat],
      model_dir: "/tmp",
      filename: "huge.gguf"
    }

    Store.register_model(model)

    assert {:error, :no_room} = Candil.ensure_engine_running(:huge_test, [])
  end
end

defmodule Candil.Scheduler.EvictionTest do
  @moduledoc """
  Prueba de que la expulsion del scheduler se EJECUTA (no solo se decide).

  El scheduler puro (`Scheduler.place/3`) ya se prueba en `scheduler_test.exs`.
  Esta prueba verifica que `ensure_engine_running/2` realmente para a las
  victimas cuando el plan es `{:evict, victims, _}`.
  """

  use ExUnit.Case, async: false

  alias Candil.{Model, Store}

  setup do
    binary = "/home/lorenzo/.local/bin/llama-server"
    model_file = "/home/lorenzo/models/gguf/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL.gguf"

    if File.exists?(binary) and File.exists?(model_file) do
      previous_adapter = Application.get_env(:apero, :http_adapter)
      Application.put_env(:apero, :http_adapter, Apero.Http.Adapter.Finch)

      on_exit(fn ->
        Application.put_env(:apero, :http_adapter, previous_adapter)
        # Limpieza defensiva: parar engines y vaciar store.
        try do
          Candil.Llm.stop_engine(:vision)
        rescue
          _ -> :ok
        end

        try do
          Candil.Llm.stop_engine(:huge_evict_test)
        rescue
          _ -> :ok
        end

        try do
          Store.deregister_model(:vision)
          Store.deregister_model(:huge_evict_test)
          Store.deregister_engine(:llama_cpp)
        rescue
          _ -> :ok
        end
      end)

      :ok
    else
      {:skip, "requiere binary local de llama-server y modelo Qwen2.5-VL-7B"}
    end
  end

  test "la expulsion ejecuta: {:evict, victims, _} para a las victimas" do
    engine = %Candil.Engine{
      alias: :llama_cpp,
      binary: "/home/lorenzo/.local/bin/llama-server",
      host: "127.0.0.1",
      port: 9991
    }

    :ok = Store.register_engine(engine)

    vision = %Model{
      alias: :vision,
      type: :local,
      engine: :llama_cpp,
      context_size: 32_768,
      vram_mb: 7472,
      usage: [:chat],
      model_dir: "/home/lorenzo/models/gguf",
      filename: "Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL.gguf"
    }

    :ok = Store.register_model(vision)

    # Arrancar vision (la victima).
    {:ok, _} = Candil.Llm.start_engine(:llama_cpp, :vision)
    Process.sleep(8000)
    assert Candil.Llm.engine_healthy?(:vision)

    # Registrar un modelo que no cabe solo pero cabe tras expulsar a vision.
    huge = %Model{
      alias: :huge_evict_test,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      vram_mb: 10_000,
      usage: [:chat],
      model_dir: "/tmp",
      filename: "huge_evict.gguf"
    }

    :ok = Store.register_model(huge)

    # Intentar arrancar huge_evict: el scheduler dice evict (vision).
    # huge_evict no puede arrancar (no hay fichero), pero la expulsion
    # de vision debe haber ocurrido antes.
    Process.flag(:trap_exit, true)
    _ = Candil.ensure_engine_running(:huge_evict_test, [])
    Process.flag(:trap_exit, false)

    # Vision debe haber sido expulsado (ya no corre).
    refute Candil.Llm.engine_healthy?(:vision)
  end
end
