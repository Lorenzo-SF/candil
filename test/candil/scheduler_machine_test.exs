defmodule Candil.Scheduler.MachineTest do
  @moduledoc """
  **Puerta de máquina**: lo que no se puede probar sin un `llama-server` y un
  GGUF de verdad.

  ## Por qué está separado

  La decisión del scheduler —«con estos números, expulsa a visión»— es pura y
  vive en `scheduler_test.exs`, que corre en CI. Lo que necesita hardware es la
  **ejecución**: que `ensure_engine_running/2` pare de verdad a la víctima, y
  que el `device_index` salga del PID medido y no del puerto.

  ## Cómo se enciende

  El módulo se salta entero salvo que estén puestas las dos variables:

      CANDIL_TEST_LLAMA_SERVER=/ruta/a/llama-server \\
      CANDIL_TEST_GGUF=/ruta/al/modelo.gguf \\
      mix test test/candil/scheduler_machine_test.exs

  Las rutas no están escritas en el fichero: una ruta absoluta a la máquina de
  quien lo escribió no es una prueba, es una costumbre.
  """

  use ExUnit.Case, async: false

  alias Candil.{Model, Store}

  @binary System.get_env("CANDIL_TEST_LLAMA_SERVER")
  @model System.get_env("CANDIL_TEST_GGUF")

  @machine? is_binary(@binary) and is_binary(@model)

  if not @machine? do
    @moduletag :skip
  end

  setup do
    previous_adapter = Application.get_env(:apero, :http_adapter)
    Application.put_env(:apero, :http_adapter, Apero.Http.Adapter.Finch)

    on_exit(fn ->
      Application.put_env(:apero, :http_adapter, previous_adapter)

      for alias_ <- [:vision, :huge_evict_test, :port_8080] do
        try do
          Candil.Llm.stop_engine(alias_)
        rescue
          _ -> :ok
        end

        try do
          Store.deregister_model(alias_)
        rescue
          _ -> :ok
        end
      end

      try do
        Store.deregister_engine(:llama_cpp)
      rescue
        _ -> :ok
      end
    end)

    engine = %Candil.Engine{
      alias: :llama_cpp,
      binary: @binary,
      host: "127.0.0.1",
      port: 9991
    }

    :ok = Store.register_engine(engine)
    :ok
  end

  defp vision_model(port) do
    %Model{
      alias: :vision,
      type: :local,
      engine: :llama_cpp,
      context_size: 32_768,
      vram_mb: 7_472,
      usage: [:chat],
      model_dir: Path.dirname(@model),
      filename: Path.basename(@model),
      port: port
    }
  end

  test "el device_index sale del PID medido, no del puerto" do
    # El puerto 8080, con la heurística vieja (`rem(8080, 100) >= 90`), caía en
    # el device 1. La GPU real es la 0. Si alguien vuelve a mirar el puerto,
    # este test se pone rojo.
    :ok = Store.register_model(vision_model(8080))
    {:ok, _} = Candil.Llm.start_engine(:llama_cpp, :vision)
    Process.sleep(8_000)

    assert [instance] = Candil.Scheduler.instances()
    assert instance.model_alias == :vision
    assert instance.device_index == 0
  end

  test "la expulsión ejecuta: {:evict, victims, _} para a las víctimas" do
    :ok = Store.register_model(vision_model(9991))
    {:ok, _} = Candil.Llm.start_engine(:llama_cpp, :vision)
    Process.sleep(8_000)
    assert Candil.Llm.engine_healthy?(:vision)

    # Un modelo que no cabe con visión dentro y sí cabe tras expulsarla. El
    # tamaño se calcula del hueco real: una constante (10_000) solo funciona
    # en una GPU de 16 GB, y en una de 24 el plan sería `{:ok, 0}` y el test
    # pasaría sin ejecutar la expulsión.
    free_mb =
      Candil.Scheduler.Devices.detect()
      |> Enum.find_value(0, & &1.free_mb)

    huge = %Model{
      alias: :huge_evict_test,
      type: :local,
      engine: :llama_cpp,
      context_size: 4096,
      vram_mb: free_mb + 1_000,
      usage: [:chat],
      model_dir: "/nonexistent",
      filename: "huge_evict.gguf"
    }

    :ok = Store.register_model(huge)

    # La decisión, antes de la ejecución: si el plan no dice «expulsa a
    # visión», este test se para aquí y no pasa por el motivo equivocado.
    assert {:evict, [:vision], 0} = Candil.Scheduler.plan(huge)

    # El arranque de `huge_evict` fallará (no hay fichero), pero la expulsión
    # ocurre antes.
    Process.flag(:trap_exit, true)
    _ = Candil.ensure_engine_running(:huge_evict_test, [])
    Process.flag(:trap_exit, false)

    refute Candil.Llm.engine_healthy?(:vision)
  end
end
