defmodule Candil.HydrateTypicalLatencyTest do
  @moduledoc """
  `typical_latency_s` estaba escrito en el `@moduledoc` de `Candil.Refusal`
  como si fuera un campo del toml, y no lo era.

  La funcion `wait_timeout_ms/2` existia y su test pasaba —porque el test le
  pasaba un **mapa** con la clave a mano— pero el campo no estaba en el
  `defstruct` de `Candil.Model`, ni lo leia `Hydrate`, y el esquema es
  permisivo: una clave desconocida carga con `:ok` y en silencio.

  O sea: escribir `typical_latency_s = 120` en el toml funcionaba, no pasaba
  nada, y el destino seguia esperando 60 s. Peor que no tener la opcion, porque
  el que lo escribe cree que ha configurado algo.

  Aqui se prueba por el camino de verdad —el toml— y no con un mapa. Y se lee
  del `Store`, que es donde `hydrate/1` deja los modelos: lo que devuelve es
  una lista de alias, no los structs.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # `as: Config` y NO `alias Candil.Config.File`: eso se llama `File` y
  # tapa el `File` de Elixir, que es justo el que escribe el toml.
  alias Candil.Config, as: Config
  alias Candil.Config.Hydrate
  alias Candil.Refusal
  alias Candil.Store

  setup do
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    on_exit(fn -> Enum.each(Store.list_models(), &Store.deregister_model(&1.alias)) end)
    :ok
  end

  defp cargar(tmp_dir, extra) do
    toml = """
    [model.lento]
    type = "local"
    engine = "llama_cpp"
    model_dir = "#{tmp_dir}"
    filename = "lento.gguf"
    usage = ["chat"]
    #{extra}
    """

    ruta = Path.join(tmp_dir, "catalogo.toml")
    File.write!(ruta, toml)
    {:ok, config} = Config.File.load(ruta)

    case Hydrate.hydrate(config) do
      %{models: errors} ->
        # Un error de validacion aqui NO es ruido de fondo: es el fallo que el
        # test quiere ver, y si no se dice el motivo el fallo siguiente
        # ("no hay ningun modelo") no dice nada.
        Enum.each(errors, fn
          {:error, name, reasons} -> flunk("'#{name}' no valida: #{inspect(reasons)}")
          _alias -> :ok
        end)

        {:ok, model} = Store.get_model(:lento)
        model
    end
  end

  describe "el campo, por el toml" do
    test "llega al modelo", %{tmp_dir: tmp_dir} do
      model = cargar(tmp_dir, "typical_latency_s = 120")

      assert model.typical_latency_s == 120
    end

    test "y el refusal lo lee de ahi", %{tmp_dir: tmp_dir} do
      model = cargar(tmp_dir, "typical_latency_s = 120")

      # Antes esto daba 60_000 aunque el toml dijera 120: el modelo no tenia el
      # campo, asi que `wait_timeout_ms/2` caia siempre al suelo.
      assert Refusal.wait_timeout_ms(model) == 240_000
    end

    test "un destino que no lo declara no lo tiene", %{tmp_dir: tmp_dir} do
      model = cargar(tmp_dir, "# nada")

      assert model.typical_latency_s == nil
      assert Refusal.wait_timeout_ms(model) == 60_000
    end

    test "un 0 no es un dato y se rechaza", %{tmp_dir: tmp_dir} do
      # El `max` de `wait_timeout_ms/2` lo dejaria en 60 s, o sea inocuo. Pero
      # `0` en un campo que significa "cuanto se demora" no es un valor malo,
      # es una confusion, y un 0 que el `max` tapa teaches a no fiarse del
      # `max`. Falla al cargar y dice por que.
      assert_raise ArgumentError, ~r/typical_latency_s de 'lento'/, fn ->
        cargar(tmp_dir, "typical_latency_s = 0")
      end
    end

    test "un valor que no es un numero se rechaza", %{tmp_dir: tmp_dir} do
      assert_raise ArgumentError, ~r/entero de segundos/, fn ->
        cargar(tmp_dir, ~s|typical_latency_s = "pronto"|)
      end
    end
  end
end
