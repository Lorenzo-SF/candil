defmodule Candil.StoreIsolationTest do
  @moduledoc """
  El Store es global, y los tests que lo tocan se pisan entre si.

  ## El problema, que es antiguo y ya estaba documentado

  `test/candil/engine/for_model_test.exs` lo dice en su propio `setup`:

  > el Store es GLOBAL, y `cli_test.exs` registra un engine llamado tambien
  > `:llama_cpp`. Con los dos ficheros en paralelo, el test que espera "no hay
  > ningun engine en el catalogo" se encuentra el de otro y falla sin que nadie
  > haya escrito mal una linea.

  Y asi estaba: **tres** ficheros de test registran engines y ninguno limpia:
  `cpu_args_test.exs`, `local_auth_test.exs` y `router_test.exs`. Los demas se
  limpian a mano, uno por uno, y el que se olvide rompe a otro sin que nadie lo
  haya tocado.

  ## Por que importa mas de lo que parece

  Un test que depende del orden no es un test que a veces falla: es un test que
  **a veces dice verde sin comprobar nada**. Y aqui el estado que se filtra es
  el catalogo entero de engines: un test que espera "no hay ninguno" puede
  encontrar el de otro y pasar, o el que espera "este engine" puede no
  encontrarlo y fallar.

  Ya ha pasado tres veces en este proyecto, con tres nombres distintos:
  - el "pin que no existia" (que en realidad era un solo candidato)
  - los consumers que no se leian del toml
  - el bucle ReAct que no cerraba

  ## Lo que se hace aqui

  El Store se vacia **antes de cada test**, no despues, y no por cada fichero
  sino una vez para todos. Asi un test que registra un engine no puede dejarlo
  hurting a otro, y nobody tiene que acordarse de limpiar.
  """

  use Candil.StoreCase

  alias Candil.Engine

  test "un engine registrado en un test es visible EN ESE test" do
    # Esto tiene que funcionar, y funciona porque `use Candil.StoreCase` mete el
    # `setup` de limpieza. Si no lo metiera, este pasaria igual (la app acaba
    # de arrancar y el Store esta vacio) — y por eso el que importa es el
    # siguiente.
    :ok = Store.register_engine(%Engine{alias: :fantasma, host: "127.0.0.1", port: 9999})
    assert {:ok, %Engine{alias: :fantasma}} = Store.get_engine(:fantasma)
  end

  test "el Store empieza vacio en cada test, no con lo que dejo el anterior" do
    # Este es EL test. Y depende del anterior: si el de arriba se ejecuto antes,
    # `:fantasma` esta en el Store ahora mismo, y que este siga en verde
    # demuestra que la limpieza pasa entre tests. Si el de arriba va despues,
    # este pasa igualmente, y entre los dos cubren los dos ordenes.
    assert {:error, :not_found} = Store.get_engine(:fantasma)
    assert Store.list_engines() == []
  end

  test "limpiar no borra el registro de adaptadores" do
    # El registro de providers es de otra cosa y lo consultan
    # `Provider.validate/1`. Si la limpieza lo llevara por delante, todos los
    # tipos parecieran "unknown" — que es EXACTAMENTE lo que paso cuando el
    # registro de adaptadores era perezoso y un test lo dejaba vacio.
    assert Candil.Provider.Adapter.registered?(:openai)

    assert :ok =
             Candil.Provider.validate(%Candil.Provider{
               alias: :probe,
               type: :openai,
               base_url: "http://x",
               api_key: "k"
             })
  end
end
