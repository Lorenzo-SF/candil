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
