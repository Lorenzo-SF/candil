# Las dos decisiones del router del 2026-10-06, a ojo.
#
#     mix run scripts/router-check.exs
#
# No hay `candil router` todavia — el Router no esta expuesto en el CLI — asi
# que esto llama al motor directamente con un catalogo de mentira. Lo que
# importa es lo que imprime: una decision FULL y una DEGRADED tienen el mismo
# shape, y la unica diferencia visible es la que acabamos de anadir.
alias Candil.{Engine, Model, Router, Store}
alias Candil.Router.{Cache, Consumer, DecisionEngine}

# ESTE SCRIPT TIENE QUE SER EL DUEÑO DEL CATALOGO, o no comprueba nada.
#
# `mix run` arranca la aplicacion ANTES de ejecutar el script, y al arrancar se
# hidrata `~/.config/candil/candil.toml` en el `Store`. Sin esta limpieza, el
# primer caso decia ":full" con `embed` presente en el toml real del usuario, y
# el del clasificador encontraba un modelo de chat del toml real y devolvia
# `:miss` en vez de fallar. Los dos casos parecian bugs del router y eran del
# script: un chequeo que depende del entorno no comprueba el entorno que cree.
#
# El script imprime el catalogo con el que DECIDIO trabajar, que es la unica
# forma de que el resultado signifique algo.
Cache.flush()
Consumer.unpin(:smoke)

importados = Candil.Store.list_models()
Enum.each(importados, &Store.deregister_model(&1.alias))
IO.puts("catalogo propio: se han fuera #{length(importados)} modelo(s) del toml real")
IO.puts("  #{inspect(Enum.map(importados, & &1.alias))}")

:ok = Store.register_engine(%Engine{alias: :llama_cpp, binary: "llama-server"})

alta = fn alias, usage ->
  :ok =
    Store.register_model(%Model{
      alias: alias,
      type: :local,
      engine: :llama_cpp,
      usage: usage,
      model_dir: "/models",
      filename: "#{alias}.gguf"
    })
end

# Un prompt que pega con la clase `code` de las reglas.
codigo = [%{role: "user", content: "refactoriza este modulo de Elixir y arregla el bug"}]

show = fn titulo, decision ->
  IO.puts("\n#{titulo}")
  IO.puts("  modelo      #{decision.model_alias}")
  IO.puts("  estrategia  #{decision.strategy}")
  IO.puts("  score       #{decision.score}")
  IO.puts("  confianza   #{inspect(decision.confidence)}")
  IO.puts("  degradado   #{inspect(decision.degraded)}")
  IO.puts("  reason      #{decision.reason}")
end

IO.puts("═" <> String.duplicate("═", 60))

alta.(:coder, [:chat, :code])
alta.(:verifier, [:chat, :reasoning])

# ── 3.3 · sin embedder: la decision sale DEGRADED ────────────────────────
{:ok, d1} = DecisionEngine.decide(codigo, [:coder, :verifier], consumer: :smoke)
show.("SIN embedder (no hay ningun modelo con usage = [:embeddings])", d1)

# ── 3.3 · con embedder: la decision sale FULL ─────────────────────────────
alta.(:embed, [:embeddings])
{:ok, d2} = DecisionEngine.decide(codigo, [:coder, :verifier], consumer: :smoke)
show.("CON embedder (usage = [:embeddings] disponible)", d2)
Store.deregister_model(:embed)

IO.puts("\n  ¿el score es el MISMO con y sin embedder?")
IO.puts("    sin: #{d1.score}   ·   con: #{d2.score}")

if d1.score == d2.score do
  IO.puts(
    "    Sí, y POR ESO hace falta la marca: dos scores iguales,\n" <>
      "    uno medido y otro no. El float no lo dice; `confidence` sí."
  )
else
  IO.puts("    Distintos (#{d1.score} vs #{d2.score}) — mira la capa que ganó en cada caso.")
end

# ── 3.4 · el clasificador LLM apagado es apagado ──────────────────────────
IO.puts("\n" <> String.duplicate("═", 60))
IO.puts("3.4 · enable_llm_classifier: false (por defecto)")

r = DecisionEngine.decide(codigo, [:coder, :verifier], consumer: :smoke)
IO.puts("  resultado   #{inspect(elem(r, 0))}")
IO.puts("  No falla aunque no haya modelo de clasificar: apagada es apagada.")

# ── 3.4 · encendido y SIN modelo: revienta diciendo cual falta ────────────
#
# El prompt tiene que FALLAR la capa de reglas. Con un prompt que casa, la
# regla decide y el clasificador no llega a ejecutarse — que es lo correcto,
# porque las capas van por coste—. Asi que este caso usa un prompt que no
# casa con ninguna palabra de ninguna regla.
IO.puts("\n" <> String.duplicate("═", 60))
IO.puts("3.4 · enable_llm_classifier: true, sin modelo de clasificar,")
IO.puts("     y con un prompt que no casa con ninguna regla")

Store.deregister_model(:coder)
Store.deregister_model(:verifier)

nada_de_reglas = [%{role: "user", content: "hola"}]

# El flag se lee de `[router]` del fichero de configuracion. Este script
# escribe uno temporal con el flag encendido, porque `Router.settings/0` lo
#Sacaba de `[router]` y no de ningun sitio mas —antes era una constante, y
# por eso `enable_llm_classifier` no se podia poner a true ni de coña.
# El flag se lee de `[router]` del fichero de configuracion. Este script
# escribe uno temporal con el flag encendido y apunta `CANDIL_CONFIG` ahi,
# porque `Router.settings/0` devolvia constantes duras: `enable_llm_classifier`
# era `false` para siempre y no habia forma de encender la cuarta capa. El
# mismo disease que `--cpu` en el arranque: un flag que parece una opcion y no
# hace nada.
tmp_dir = Path.join(System.tmp_dir!(), "candil-router-check-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp_dir)
tmp_config = Path.join(tmp_dir, "candil.toml")

File.write!(tmp_config, """
[general]
data_dir = "#{tmp_dir}"
log_dir  = "#{tmp_dir}/logs"

[router]
enable_llm_classifier = true
""")

System.put_env("CANDIL_CONFIG", tmp_config)
IO.puts("  (flag leido de: #{tmp_config})")
IO.puts("  enable_llm_classifier = #{inspect(Router.settings().enable_llm_classifier)}")

case DecisionEngine.decide(nada_de_reglas, [:coder, :verifier], consumer: :smoke) do
  {:classifier_unavailable, error} ->
    IO.puts("  HA FALLADO, como debe ser:")
    IO.puts("    reason  #{inspect(error.reason)}")
    IO.puts("    hint    #{error.context[:hint]}")

  otro ->
    IO.puts("  NO ha fallado, y eso es un bug: #{inspect(otro)}")
end