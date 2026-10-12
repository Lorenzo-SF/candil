# ══════════════════════════════════════════════════════════════════════════
#  LA METRICA DEL TRIBUNAL, CONTRA MODELOS DE VERDAD.
#
#  DISENO-MOTOR.md §10 pone una condición antes de meter un LLM como
#  clasificador: se mide qué fracción de decisiones resolvió la política.
#
#      Si es el 97%, al LLM se le llama el 3% y es ruido caro.
#      Si es el 60%, EL MOTOR ESTÁTICO ESTÁ MAL HECHO
#      y hay que arreglarlo antes de meter un modelo.
#
#  Aquí no hay embedder ni clasificador de mentira: los dos llaman a modelos
#  reales de la RTX 5080. Un recuento con vectores de mentira no mide nada.
#
#      CANDIL_DATA_DIR=$(mktemp -d) mix run scripts/tribunal-real.exs
# ══════════════════════════════════════════════════════════════════════════
alias Candil.{Engine, Inference, Model, Router, Store}
alias Candil.Embeddings.Adapter
alias Candil.Router.Classifier

ms = fn -> System.monotonic_time(:millisecond) end

# ── El embedder REAL: el mismo camino que ya usa Candil ────────────────────
defmodule EmbedderReal do
  @moduledoc false
  @behaviour Candil.Embeddings.Adapter

  @impl true
  def embed(texts, _opts), do: Candil.Inference.embed_local(:embed, texts, [])

  @impl true
  def dimension(_opts), do: 1536

  @impl true
  def supports?(:text), do: true
  def supports?(_), do: false
end

# ── El clasificador REAL: llama al MODELO, nunca al router ────────────────
#
# La regla de `Scorer` es literal: un clasificador llama al modelo
# directamente. Si este módulo llamara a `Router.route/2`, se llamaria a si
# mismo para siempre.
defmodule ClasificadorReal do
  @moduledoc false
  @behaviour Candil.Router.Classifier

  @prompt """
  Clasifica esta peticion. Responde SOLO con una linea de la forma:
  NIVEL=fast|NORMAL|DEEP CONFIANZA=0.0-1.0

  - fast: es una peticion corta y directa, sin razonamiento.
  - normal: hay que redactar o explicar algo, razonamiento sencillo.
  - DEEP: hay que analizar, comparar o demostrar algo no trivial.

  PETICION:
  """

  @impl true
  def enabled?(_opts), do: true

  @impl true
  def name, do: :clasificador_real

  @impl true
  def classify(messages, _opts) do
    texto = messages |> List.last() |> Map.get(:content, "")

    msgs = [%{role: "user", content: @prompt <> texto}]

    case Candil.Inference.chat_local(:tribunal_clf, msgs, max_tokens: 200) do
      {:ok, respuesta} -> parse(respuesta, texto)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(respuesta, original) do
    texto = Map.get(respuesta, :content, "") || ""
    cuerpo = if String.trim(texto) == "", do: Map.get(respuesta, :reasoning, "") || texto, else: texto

    con_nivel = Regex.run(~r/NIVEL\s*=\s*(fast|NORMAL|DEEP)/i, cuerpo)
    con_conf = Regex.run(~r/CONFIANZA\s*=\s*([01](?:\.\d+)?)/i, cuerpo)

    nivel =
      case con_nivel do
        [_, n] -> n |> String.downcase() |> normaliza()
        _ -> :normal
      end

    confianza =
      case con_conf do
        [_, c] -> c |> String.to_float() |> max(0.0) |> min(1.0)
        _ -> 0.5
      end

    {:ok, %{difficulty: nivel, confidence: confianza, why: "lo dijo #{original |> String.slice(0, 40)}"}}
  end

  defp normaliza("fast"), do: :fast
  defp normaliza("normal"), do: :normal
  defp normaliza(_), do: :deep
end

# ══════════════════════════════════════════════════════════════════════════
IO.puts("\n═══ EL TRIBUNAL, CON MODELOS DE VERDAD ═══\n")

# ── Dos motores reales ─────────────────────────────────────────────────────
engine = %Engine{
  alias: :llama_cpp,
  binary: "/home/lorenzo/.local/bin/llama-server",
  host: "127.0.0.1",
  port: 9999
}

:ok = Store.register_engine(engine)

alta = fn engine_para, model ->
  IO.puts("  arrancando #{model.alias} en el puerto #{engine_para.port}…")
  {:ok, _} = Engine.start(engine_para, model)

  sano =
    Enum.reduce_while(1..90, false, fn _, _ ->
      if Engine.healthy?(model.alias, 3000), do: {:halt, true}, else: (Process.sleep(1000); {:cont, false})
    end)

  if sano, do: IO.puts("    sano."), else: (IO.puts("    NO SANO."); System.halt(1))
end

chat_model = %Model{
  alias: :tribunal_clf,
  type: :local,
  engine: :llama_cpp,
  model_dir: "/home/lorenzo/models/gguf",
  filename: "agentica-org_DeepCoder-14B-Preview-Q4_K_L.gguf",
  context_size: 8192,
  port: 9999,
  usage: [:chat, :completion],
  gpu_layers: -1,
  exclusive: true
}

embed_model = %Model{
  alias: :embed,
  type: :local,
  engine: :llama_cpp_embed,
  model_dir: "/home/lorenzo/models/gguf",
  filename: "jina-code-embeddings-1.5b-Q8_0.gguf",
  context_size: 8192,
  port: 9996,
  usage: [:embeddings],
  gpu_layers: -1,
  model_args: ["--embedding", "--pooling", "last", "--embd-normalize", "2"]
}

# El embedder necesita SU PROPIO engine con SU puerto. `Engine.start/2` saca el
# puerto del ENGINE, no del modelo, y con el mismo engine para los dos el
# segundo `llama-server` sale con codigo 1 porque el puerto ya esta cogido —
# que es el mismo sintoma que "no cabe en la tarjeta", y asi se buscan horas un
# bug de memoria que no existe.
embed_engine = %{engine | alias: :llama_cpp_embed, port: 9996}
:ok = Store.register_engine(embed_engine)

:ok = Store.register_model(chat_model)
:ok = Store.register_model(embed_model)
alta.(engine, chat_model)
alta.(embed_engine, embed_model)

# ── Los candidatos, con descripciones de verdad ────────────────────────────
# La capa :embedding compara el prompt contra la `description` de cada modelo.
# Sin descripciones no hay nada que comparar, y el 0% que saldría sería de un
# catálogo vacío, no de un motor malo.
candidatos = [
  {:coder,
   [
     :chat,
     :code,
     :completion
   ], "escribe, arregla, depura y refactoriza código: función, módulo, bug, test, compila, type, pattern match"},
  {:verifier,
   [:chat, :reasoning], "razona, demuestra y audita: analiza, compara, explica por qué, prueba, justifica, revisa"},
  {:redactor,
   [:chat, :completion], "redacta prosa y documentación: resume, redacta, escribe una guía, storytelling, translated"}
]

for {alias, usage, desc} <- candidatos do
  :ok =
    Store.register_model(%Model{
      alias: alias,
      type: :local,
      engine: :llama_cpp,
      model_dir: "/home/lorenzo/models/gguf",
      filename: "agentica-org_DeepCoder-14B-Preview-Q4_K_L.gguf",
      context_size: 8192,
      port: 9999,
      usage: usage,
      description: desc,
      gpu_layers: -1
    })
end

:ok = Adapter.register(:real, EmbedderReal)
:ok = Classifier.register(:real, ClasificadorReal)

# ── Los flags del router, con las DOS capas encendidas ─────────────────────
tmp = Path.join(System.tmp_dir!(), "candil-tribunal-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)

File.write!(Path.join(tmp, "candil.toml"), """
[general]
data_dir = "#{tmp}"

[router]
embedder = "real"
classifier = "real"
enable_llm_classifier = true
enable_cache = false
embedding_threshold = 0.55
confidence_threshold = 0.5
""")

System.put_env("CANDIL_CONFIG", Path.join(tmp, "candil.toml"))

IO.puts("\n  capa :embedding  encendida (embedder real, jina-code-embeddings)")
IO.puts("  capa :llm        encendida (clasificador real, DeepCoder-14B)")
IO.puts("  cache            apagada, para no contar la misma pregunta dos veces\n")

# ── Escuchar el evento ─────────────────────────────────────────────────────
handler_id = "tribunal-real"

:telemetry.attach(handler_id, [:candil, :router, :decision], fn _n, meas, meta, _ -> send(self(), {:d, meas, meta}) end, nil)

# ── Los prompts ────────────────────────────────────────────────────────────
# El segundo elemento es lo que uno QUIERE que gane. No es "la respuesta
# correcta": es la que el humansabe que deberia ganar, y es lo unico que
# permite decir si la capa sirve o solo si responde.
prompts = [
  {"refactoriza este modulo de Elixir y dime por que esta roto", :coder},
  {"arregla el bug de la funcion recursiva que desborda la pila", :coder},
  {"escribe los tests para este modulo y dime por que fallan", :coder},
  {"analiza por que este codigo es lento y demuestra cual es el cuello de botella", :verifier},
  {"compara estas dos arquitecturas y justifica cual escolherias", :verifier},
  {"explica por que una GPU no puede partir una inferencia a medias", :verifier},
  {"revisa esta politica de la empresa y demuestra que cumple la norma", :verifier},
  {"redacta la documentacion de este modulo para el README", :redactor},
  {"resume este informe de tres paginas en cinco frases", :redactor},
  {"escribe un email al cliente explicando la retraso", :redactor},
  {"hola", :coder},
  {"refactoriza y arregla el bug del modulo de Elixir", :coder}
]

# Cada prompt se enruta por el camino completo, con el cache apagado.
defmodule Medir do
  @moduledoc false
end

resultados =
  Enum.map(prompts, fn {prompt, esperado} ->
    t0 = System.monotonic_time(:native)

    decision =
      case Router.route([%{role: "user", content: prompt}],
             consumer: :tribunal,
             candidates: [:coder, :verifier, :redactor],
             skip_cache: true
           ) do
        {:ok, d} -> d
        other -> other
      end

    ms =
      System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

    evento =
      receive do
        {:d, meas, meta} -> {meas, meta}
      after
        200 -> {nil, nil}
      end

    {prompt, esperado, decision, ms, evento}
  end)

# ══════════════════════════════════════════════════════════════════════════
IO.puts("┌───────────────────────────────────────────────────────────────────────────────┐")
IO.puts("│  PROMPT                       ESPERADO   GANADO    CAPAS QUE CORRIERON   ms  │")
IO.puts("└───────────────────────────────────────────────────────────────────────────────┘")

for {prompt, esperado, decision, ms, {_, meta}} <- resultados do
  {ganado, _estrategia} =
    case decision do
      %{model_alias: m} -> {m, nil}
      other -> {other, nil}
    end

  capas = if meta, do: Enum.join(meta.layers_ran, ","), else: "-"
  marca = if ganado == esperado, do: " ", else: "✗"

  IO.puts(
    String.slice(prompt, 0, 26) <>
      String.duplicate(" ", max(1, 27 - String.length(prompt))) <>
      "#{marca}#{inspect(esperado)}  #{String.slice(inspect(ganado), 0, 9)}  #{String.pad_trailing(capas, 22)} #{ms}"
  )
end

IO.puts("\n")

# ── El recuento ────────────────────────────────────────────────────────────
validas = Enum.filter(resultados, fn {_, _, d, _, _} -> match?(%{strategy: _}, d) end)
total = length(validas)

con_llm = Enum.count(validas, fn {_, _, _, _, {_, meta}} -> meta && meta.llm_called end)
por_capa = Enum.frequencies_by(validas, fn {_, _, d, _, _} -> d.strategy end)

aciertos = Enum.count(validas, fn {_, e, d, _, _} -> d.model_alias == e end)

IO.puts("═══ EL RECUENTO ═══\n")
IO.puts("  decisiones medidas ............. #{total}")
IO.puts("  el prompt llego al que quería .. #{aciertos}/#{total}")

IO.puts("\n  quién decidió cada una:")

for {capa, n} <- Enum.sort_by(por_capa, fn {_, n} -> -n end) do
  IO.puts("    #{String.pad_trailing(inspect(capa), 12)} #{n}  (#{Float.round(n * 100 / total, 1)}%)")
end

# ── LA MÉTRICA ─────────────────────────────────────────────────────────────
#
# La fracción que el tribunal de §10 pide: cuánto resolvió la política sin
# llamar a un modelo. Y el coste: cuántas veces se llamó al LLM.
#
# El denominador son las DECISIONES, una por petición — que es justo la
# trampa de la que este script avisa: si el evento se emitiera por capa en
# vez de por decisión, este `total` seria mayor y el porcentaje de LLM mas
# bajo de lo que es.
llamadas = con_llm
estatico = total - con_llm
pct_llm = if total == 0, do: 0.0, else: Float.round(llamadas * 100 / total, 1)
pct_estatico = if total == 0, do: 0.0, else: Float.round(estatico * 100 / total, 1)

IO.puts("""

  ══════════════════════════════════════════════
  LA METRICA DEL TRIBUNAL
  ══════════════════════════════════════════════
    lo resolvio la politica estatica .... #{estatico}/#{total}  = #{pct_estatico}%
    hubo que llamar al LLM ............... #{llamadas}/#{total}  = #{pct_llm}%

    Si la politica sale por encima del 90%: la afinidad esta bien
    y el LLM se llama de vez en cuando. Si sale por debajo del 70%,
    el motor ESTATICO esta mal hecho, y meter un modelo encima
    taparia el problema de las señales.
  ══════════════════════════════════════════════
""")

case pct_llm do
  p when p > 30 -> IO.puts("  VEREDICTO: el LLM se llama #{p}% de las veces.\n  HAY QUE ARREGLAR LAS SEÑALES antes de meterlo.\n")
  p when p > 10 -> IO.puts("  VEREDICTO: el LLM se llama #{p}% de las veces. Zona intermedia: hay señales debiles.\n")
  p -> IO.puts("  VEREDICTO: el LLM se llama #{p}% de las veces. La politica estatica aguanta.\n")
end

# ── La tabla de similitudes ────────────────────────────────────────────────
# La capa :embedding compara el prompt contra la `description` de cada modelo.
# Aquí se ve eso a pelo, con el embedder REAL, para poder MOVER el umbral
# mirándolo —y no adivinando— que es lo que dice el documento.
#
# Ojo con lo que significa un 0.30 aquí: si los tres scores de un prompt son
# 0.31, 0.30 y 0.29, bajar el umbral no arregla nada, porque el catalog no
# DISTINGUE. Ese prompt es indistinguible para cualquier umbral.
defmodule Similitudes do
  @moduledoc false

  def cosine(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    na = a |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
    nb = b |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
    if na == 0 or nb == 0, do: 0.0, else: dot / (na * nb)
  end

  def tabla(aliases, lista_prompts) do
    descripciones = Enum.map(aliases, fn a -> elem(List.keyfind(docs(), a, 0), 1) end)

    Enum.map(lista_prompts, fn {prompt, _esperado} ->
      textos = [prompt | descripciones]

      case Candil.Inference.embed_local(:embed, textos, []) do
        {:ok, [pv | vs]} ->
          {prompt, Enum.zip(aliases, Enum.map(vs, &cosine(pv, &1)))}

        _ ->
          {prompt, []}
      end
    end)
  end

  def docs do
    [
      {:coder,
       "escribe, arregla, depura y refactoriza código: función, módulo, bug, test, compila, type, pattern match"},
      {:verifier, "razona, demuestra y audita: analiza, compara, explica por qué, prueba, justifica, revisa"},
      {:redactor, "redacta prosa y documentación: resume, redacta, escribe una guía, storytelling, translated"}
    ]
  end
end

IO.puts("\n═══ LA TABLA DE SIMILITUDES (embedder real) ═══\n")
IO.puts("  La capa :embedding NO ha ganado en ningun prompt. Esto es lo que vio:")
IO.puts("")

for {prompt, scores} <- Similitudes.tabla([:coder, :verifier, :redactor], prompts) do
  cells =
    Enum.map_join(scores, "  ", fn {a, s} ->
      "#{a}=#{Float.round(s, 3)}"
    end)

  IO.puts("  #{String.slice(prompt, 0, 30) |> String.pad_trailing(31)} #{cells}")
end

IO.puts("""
  ─────────────────────────────────────────────────────────────────
  Umbral de la capa :embedding: 0.55
""")

# ── Limpieza ───────────────────────────────────────────────────────────────
:telemetry.detach(handler_id)
System.delete_env("CANDIL_CONFIG")
File.rm_rf(tmp)