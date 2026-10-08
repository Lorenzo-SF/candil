ExUnit.start()

Mox.defmock(Candil.HTTPAdapterMock, for: Apero.Http.Adapter)

# Use the mock adapter for ALL tests by default (deterministic, no real
# network). Tests that need specific behavior set expectations or stubs;
# the "unreachable host" tests stub a connection error.
Application.put_env(:apero, :http_adapter, Candil.HTTPAdapterMock)

# Ensure the Registry is started for tests that need it
case Registry.start_link(keys: :unique, name: Candil.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# ── Aislamiento del Store entre tests ─────────────────────────────────────────
#
# El Store son tablas ETS **globales**, y el fallo no respeta ficheros: el ultimo
# test que registro un engine se lo deja al primero del siguiente. Tres ficheros
# de test lo hacen y ninguno limpia, y el resultado es un test que a veces falla
# por el orden.
#
# Eso es peor que un test que falla siempre: uno que falla siempre se ve, y uno
# que falla a veces **se cree**. Un test que espera "no hay ningun engine" puede
# encontrar el de otro y pasar, o el que espera "este engine" puede no encontrarlo
# y caer, sin que nadie haya escrito mal una linea.
#
# Por eso se limpia ANTES de cada test y UNA sola vez para todos, en vez de que
# cada fichero se acuerde. Asi un test no deja rastro en otro.
#
# Y ya ha pasado tres veces en este proyecto con tres nombres distintos: el "pin
# que no existia" (que era un solo candidato), los consumers que no se leian del
# toml, y el bucle ReAct que no cerraba. Los tres decian "esto funciona".
#
# Lo que NO se toca es el registro de adaptadores de provider: lo consulta
# `Provider.validate/1` desde `Store.register/2`, y vaciarlo haria que todos los
# tipos parecieran "unknown".

# `Candil.StoreCase`: el caso base que vacia el Store entre tests. Ver su
# @moduledoc para por que no es solo limpieza, sino por que sin ella hay tests
# que a veces dicen verde sin comprobar nada.
Code.require_file("support/store_case.ex", __DIR__)
