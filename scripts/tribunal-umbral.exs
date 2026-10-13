# ¿Hace falta un LLM, o solo hay que mover la raya?
#
# La pregunta mal planteada es «los estaticos fallan, meto un LLM». La bien
# planteada es **«¿los estaticos fallan por el umbral o por el catalogo?»**, y
# esa se responde barriendo el umbral y mirando CUANTO resuelven y CUANTO
# aciertan a la vez.
#
# Si al bajar la raya sube la resolucion sin que caiga el acierto, el LLM no
# hace falta: sobra. Si el acierto se hunde, el catalogo no distingue y ahi si.

alias Candil.{Engine, Model, Store}

engine = %Engine{alias: :e, binary: "/home/lorenzo/.local/bin/llama-server", host: "127.0.0.1", port: 9996}
:ok = Store.register_engine(engine)

emb = %Model{alias: :emb, type: :local, engine: :e, model_dir: "/home/lorenzo/models/gguf",
  filename: "jina-code-embeddings-1.5b-Q8_0.gguf", context_size: 8192, port: 9996,
  usage: [:embeddings], gpu_layers: -1,
  model_args: ["--embedding", "--pooling", "last", "--embd-normalize", "2"]}

:ok = Store.register_model(emb)
{:ok, _} = Engine.start(engine, emb)
Enum.reduce_while(1..90, false, fn _, _ ->
  if Engine.healthy?(:emb, 3000), do: {:halt, true}, else: (Process.sleep(1000); {:cont, false})
end)

defmodule E do
  @behaviour Candil.Embeddings.Adapter
  @impl true
  def embed(t, _), do: Candil.Inference.embed_local(:emb, t, [])
  @impl true
  def dimension(_), do: 1536
  @impl true
  def supports?(:text), do: true
  def supports?(_), do: false
end

Candil.Embeddings.Adapter.register(:real, E)

descs = %{
  programador: "escribe, arregla, depura y refactoriza codigo: funcion, modulo, bug, test, compila, dialyzer, mix",
  revisor: "revisa, audita y demuestra: verifica, compara, justifica, explica por que, analiza, revisa",
  redactor: "redacta prosa y documentacion: release notes, changelog, guia, resumen, redacta"
}

for {a, d} <- descs,
  do: :ok = Store.register_model(%Candil.Model{alias: a, type: :local, engine: :e,
    model_dir: "/m", filename: "x.gguf", context_size: 4096, port: 9996,
    usage: [:chat], description: d})

tmp = Path.join(System.tmp_dir!(), "candil-umbral-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)

multilingualue = [
  {"es", "refactoriza este módulo de Elixir y explica por qué falla", :programador},
  {"es", "añade tests para el nuevo endpoint", :programador},
  {"es", "revisa el PR y dime si la lógica es correcta", :revisor},
  {"es", "escribe el changelog de la 5.0", :redactor},
  {"es", "optimiza la consulta que se hace lenta", :programador},
  {"es", "investiga por qué la suite falla en CI", :revisor},
  {"es", "corrige el error de tipos del compilador", :programador},
  {"es", "migrar la base de datos sin perder datos", :programador},
  {"es", "implementa paginación en el endpoint", :programador},
  {"es", "arregla la condición de carrera en la cola", :programador},
  {"es", "analiza este algoritmo y dime si es O(n)", :revisor},
  {"fr", "refactorise ce module et expliquez pourquoi", :programador},
  {"fr", "ajoutez des tests pour le point de terminaison", :programador},
  {"fr", "verifiez cette logique et dites-moi", :revisor},
  {"fr", "ecrivez le changelog de la 5.0", :redactor},
  {"fr", "optimisez la requete qui est lente", :programador},
  {"fr", "corrigez le bug de la file d'attente", :programador},
  {"de", "refactorisiere dieses Modul und erklaere", :programador},
  {"de", "fuege Tests fuer den Endpunkt hinzu", :programador},
  {"de", "pruefe diese Logik und sag mir ob sie korrekt ist", :revisor},
  {"de", "schreibe den Changelog fuer 5.0", :redactor},
  {"de", "optimiere die Abfrage die langsam ist", :programador}
]

reales =
  "/tmp/candil-medicion/corpus.txt"
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.map(fn l ->
    [repo, s] = String.split(l, "\t", parts: 2)
    # Sin «esperado» conocido: un asunto de commit no trae la respuesta buena,
    # y عليها solo se cuenta CUANTO resuelve, no si acierta.
    {repo, s, nil}
  end)

corpus = reales ++ Enum.map(multilingualue, fn {l, t, e} -> {l, t, e} end)

IO.puts("""
════ ¿HACE FALTA UN LLM, O SOLO MOVER LA RAYA? ════
  corpus: #{length(corpus)} peticiones (es/en/fr/de)
  «esperado» en las multilingües; en las reales no hay, y se cuentan solo las resueltas.

  umbral   resuelve   de esas, acierta   manos al LLM
  ─────────────────────────────────────────────────────
""")

for umbral <- [0.55, 0.50, 0.45, 0.40, 0.35, 0.30, 0.25, 0.20] do
  File.write!(Path.join(tmp, "candil.toml"), """
  [general]
  data_dir = "#{tmp}"

  [router]
  embedder = "real"
  enable_llm_classifier = false
  enable_cache = false
  embedding_threshold = #{umbral}
  rule_threshold = 0.20
  """)

  System.put_env("CANDIL_CONFIG", Path.join(tmp, "candil.toml"))

  filas =
    Enum.map(corpus, fn {l, t, e} ->
      d =
        case Candil.Router.route([%{role: "user", content: t}],
               consumer: :u, candidates: [:programador, :revisor, :redactor], skip_cache: true) do
          {:ok, d} -> d
          _ -> nil
        end

      {l, t, e, d}
    end)

  resueltas = Enum.filter(filas, fn {_, _, _, d} -> d && d.strategy != :default end)

  # acierto: solo donde hay un «esperado» de verdad, que son las multilingües
  con_jalo = Enum.filter(resueltas, fn {_, _, e, _} -> not is_nil(e) end)
  aciertos = Enum.count(con_jalo, fn {_, _, e, d} -> d.model_alias == e end)

  manos = length(filas) - length(resueltas)

  IO.puts(
    "  #{Float.round(umbral, 2)}    #{String.pad_trailing(to_string(length(resueltas)) <> "/" <> to_string(length(filas)), 10)}" <>
      "  #{String.pad_trailing("#{aciertos}/#{length(con_jalo)}", 20)}  #{manos}"
  )
end

IO.puts("""

  Leerse asi:
   · «resuelve» sube al bajar la raya, y NO TIENE POR QUE BAJAR EL ACIERTO.
   · Si el acierto se mantiene, el LLM sobra: sobran sus 21 s y la pelea por la GPU.
   · Si el acierto se hunde, el catalogo no distingue y ahi si hace falta mirar
     un LLM — y no como capa, sino como senal mas.
""")