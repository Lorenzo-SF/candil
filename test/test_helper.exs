# ── El suelo: la suite NUNCA escribe en el `~/.candil` del developer ──────────
#
# El Store (ETS) esta limpio desde 2026-10-07. El otro estado global **no lo
# estaba**: `Candil.Instances` escribe un `instances.json` en disco, y varios
# tests llamaban a `Instances.put/2` o a `run_model(detach: true)` sin poner
# `CANDIL_DATA_DIR`. Cada uno de esos tests escribia en el home de quien
# ejecutase la suite.
#
# Lo que cuesta, medido el 2026-10-10: cuatro tests de `cli_test.exs` se
# pusieron rojos en CI con una instancia `argv_m` en el 19991 que **nadie de
# ese fichero habia creado**. En local pasaban, porque en local si habia un
# `~/.candil` con una instancia dentro — o porque la suite ya habia dejado una
# antes. Depende de la maquina, que es la forma mas mala de depender.
#
# El propio `Candil.Instances` avisa de esto en su `@doc`:
# *"a test that writes instances.json into the developer's real ~/.candil is a
# test nobody runs twice"*. El aviso estaba desde antes. El suelo no.
#
# Esto es un suelo, no el aislamiento: los tests que necesitan su propio
# directorio siguen poniendo el suyo, que es mas fuerte. Esto garantiza que
# **ningun** test pueda escribir fuera del temporal, este en el fichero que
# este.
suite_dir =
  Path.join(System.tmp_dir!(), "candil-suite-#{System.unique_integer([:positive])}")

File.mkdir_p!(suite_dir)
System.put_env("CANDIL_DATA_DIR", suite_dir)
ExUnit.after_suite(fn _ -> File.rm_rf(suite_dir) end)

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
