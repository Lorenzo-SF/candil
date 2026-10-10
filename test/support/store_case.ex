defmodule Candil.StoreCase do
  @moduledoc """
  El caso base de los tests que tocan el Store.

  ## Por que existe

  El Store son tablas ETS **globales**, y el fallout no respeta ficheros: el
  ultimo test que registro un engine se lo deja al primero del siguiente. Tres
  ficheros de test lo hacen y ninguno limpia, y el resultado es un test que a
  veces falla por el orden.

  Eso es **peor** que un test que falla siempre: uno que falla siempre se ve, y
  uno que falla a veces **se cree**. Un test que espera «no hay ningun engine»
  puede encontrar el de otro y pasar, o el que espera «este engine» puede no
  encontrarlo y caer, sin que nadie haya escrito mal una linea.

  Y ya ha pasado tres veces en este proyecto con tres nombres distintos: el «pin
  que no existia» (que era un solo candidato), los consumers que no se leian del
  toml, y el bucle ReAct que no cerraba. Los tres decian «esto funciona».

  ## Lo que tambien se aisla: el disco

  `Candil.Instances` escribe un `instances.json` en `CANDIL_DATA_DIR`, y eso no es
  ETS: es un fichero. El `setup` tambien le da un directorio **por test**, para
  que una instancia registrada por uno no aparezca en el `status` del otro. El
  suelo de `test_helper.exs` evita que alguien escriba en el `~/.candil` real;
  esto evita que un test ensucie a otro.

  ## Lo que NO se toca

  El registro de adaptadores de provider. Lo consulta `Provider.validate/1` desde
  `Store.register/2`, y vaciarlo haria que todos los tipos parecieran «unknown».
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Candil.StoreCase
      alias Candil.Store

      # `async: false` por defecto porque el Store es GLOBAL. Un test que
      # registra un engine no puede correr en paralelo con otro que espere no
      # encontrar engines. Quien quiera `async: true` tiene que decirlo, y
      # entonces tiene que saber lo que hace.
      use ExUnit.Case, async: false
    end
  end

  setup do
    empty_store()

    # Y tambien un `CANDIL_DATA_DIR` propio por test. El Store son ETS, pero
    # `Candil.Instances` escribe un fichero en disco, y ese estado tambien es
    # global: un test que registra una instancia la deja al siguiente. Con un
    # directorio por test, la 实例 de uno no aparece en el `status` del otro.
    dir = Path.join(System.tmp_dir!(), "candil-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("CANDIL_DATA_DIR")
    System.put_env("CANDIL_DATA_DIR", dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: System.put_env("CANDIL_DATA_DIR", previous)
    end)

    :ok
  end

  @doc """
  Vacia el Store de engines, modelos y providers.
  """
  @spec empty_store() :: :ok
  def empty_store do
    for table <- [:candil_llm_engines, :candil_llm_models, :candil_llm_providers] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end
end
