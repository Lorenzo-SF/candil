# Las doce preguntas del enrutado, con el catalogo REAL de esta maquina:
# a donde va cada una, y si el destino existe de verdad en disco.
#
#     mix run scripts/enrutado-12-preguntas.exs
#
# Nace de una medicion repetida el 2026-10-16: el 11/12 se habia medido con un
# catalogo en el que `coder` —el `model_default`— apuntaba a una cuantizacion
# que no existia en disco. El numero decia a donde va cada pregunta, pero no
# que el destino pudiera contestar. Este guion cuenta las dos cosas: el
# veredicto, y el fichero.
#
# No arranca modelos: comprobar que el fichero esta es barato y se puede correr
# siempre. Arrancarlos de verdad se hizo a mano el 2026-10-16, y esta medido en
# `docs/09-deuda-y-pendientes` §5.
alias Candil.{Router, Store}
alias Candil.Config.Hydrate

ruta = System.get_env("CANDIL_CONFIG") || Path.expand("~/.config/candil/candil.toml")
{:ok, config} = Candil.Config.File.load(ruta)
_h = Hydrate.hydrate(config)

casos = [
  # ── SIMPLES ──────────────────────────────────────────────────────────────
  {"es", "arregla el bug de la función recursiva que desborda la pila", :programador},
  {"es", "analiza por qué este algoritmo es tan lento y demuestra cuál es el cuello de botella",
   :revisor},
  {"es", "escribe el changelog de la 5.0 y resume las diferencias", :redactor},
  {"fr", "corrigez le bug dans la fonction recursive", :programador},
  {"fr", "analysez pourquoi cet algorithme est lent et demontrez le goulot", :revisor},
  {"de", "behebe den Fehler in dieser rekursiven Funktion", :programador},
  {"en", "fix the bug in this recursive function", :programador},
  # ── COMPUESTOS ───────────────────────────────────────────────────────────
  {"es", "arregla el error y explica por que pasaba, para el changelog", :compuesto_code},
  {"es", "analiza el bug y escribe el informe", :compuesto_reasoning},
  {"fr", "corrigez le bug et explique pourquoi, pour le changelog", :compuesto_code},
  {"de", "behebe den Fehler und erklaere warum, fuer den Changelog", :compuesto_code},
  {"en", "fix the bug and explain why it happened, for the changelog", :compuesto_code}
]

esperado = %{
  :programador => :coder,
  :revisor => :verifier,
  :redactor => :coder_lite,
  # Un compuesto de codigo es una tarea de codigo: el codigo va a coder y el
  # "explica por que" lo anade el modelo. Un compuesto de razonamiento es lo
  # que de verdad no tiene destino unico.
  :compuesto_code => :coder,
  :compuesto_reasoning => :verifier
}

IO.puts("\n=============== A DONDE VA CADA PREGUNTA ===============")
IO.puts("catalogo: #{ruta}\n")

{aciertos, elegidos} =
  Enum.reduce(casos, {0, MapSet.new()}, fn {idioma, texto, clase}, {aciertos, elegidos} ->
    mensajes = [%{role: "user", content: texto}]

    {:ok, cands} = Router.candidates(:default)
    resultado = Candil.Router.DecisionEngine.decide(mensajes, cands, consumer: :default)

    {donde, estrategia, score} =
      case resultado do
        {:ok, d} -> {d.model_alias, d.strategy, d.score}
        {:error, e} -> {{:error, e}, :error, nil}
      end

    bien? = donde == esperado[clase]
    marca = if bien?, do: "OK  ", else: "FALLA"

    extra =
      case resultado do
        {:ok, _} -> "estrategia=#{estrategia} score=#{score}"
        _ -> ""
      end

    IO.puts(
      "  #{marca} #{idioma} #{String.pad_trailing(to_string(clase), 20)} -> " <>
        "#{String.pad_trailing(inspect(donde), 24)} #{extra}"
    )

    IO.puts("         \"#{texto}\"")

    aciertos = if bien?, do: aciertos + 1, else: aciertos

    {aciertos, MapSet.put(elegidos, donde)}
  end)

IO.puts("\n#{aciertos}/#{length(casos)} a donde deberia")

IO.puts("\n=============== LOS DESTINOS EXISTEN EN DISCO? ===============\n")

gb = fn bytes -> Float.round(bytes / 1_000_000_000, 1) end

elegidos
|> Enum.filter(&is_atom/1)
|> Enum.sort()
|> Enum.each(fn alias ->
  case Store.get_model(alias) do
    {:ok, %{type: :local, model_dir: dir, filename: file}}
    when is_binary(dir) and is_binary(file) ->
      fichero = Path.join(Path.expand(dir), file)

      case File.stat(fichero) do
        {:ok, %{size: bytes}} ->
          IO.puts("  OK      #{alias} · #{file} · #{gb.(bytes)} GB")

        {:error, razon} ->
          IO.puts("  FALTA   #{alias} · #{fichero} · #{inspect(razon)}")
      end

    {:ok, modelo} ->
      IO.puts("  #{modelo.type}    #{alias} · sin fichero propio (lo sirve otro lado)")

    {:error, :not_found} ->
      IO.puts("  FALTA   #{alias} · no esta en el Store")
  end
end)
