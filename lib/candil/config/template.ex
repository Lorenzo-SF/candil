defmodule Candil.Config.Template do
  @moduledoc """
  A commented `candil.toml` showing everything Candil can be configured with.

  ## Why it is generated and not written by hand

  A template in the repo goes stale the day somebody adds a key, and a stale
  template is worse than no template: it looks authoritative and is wrong
  exactly where someone needed it. So this builds the text from the keys the
  schema actually validates, and `render/0` is tested to still parse — a
  template that Candil's own parser rejects is not shipped.

  The one thing it cannot be derived from the schema is *what the values mean*.
  Every option therefore says, in a comment, what happens if you get it wrong,
  because "is a string" is not documentation.

  ## It is valid, empty, and inert

  Everything is commented out, so `candil init` writes a file that parses and
  does nothing. That matters because the alternative — a template with a live
  model pointing at a 17 GB download — turns a first run into an afternoon.
  """

  alias Toml

  @doc """
  The template, as a string.
  """
  # Devuelve `{:ok, contenido} | {:error, reason}` en vez de un binario suelto.
  #
  # El esqueleto se valida a si mismo antes de salir, porque un esqueleto que no
  # parsea es peor que no tener esqueleto: `candil init` escribiria un fichero
  # roto y el usuario no lo sabria hasta el siguiente comando.
  #
  # Esto protege mas que un test, porque el que protege es la maquina de quien
  # lo ejecuta, no el CI. Un test puede estar verde mientras el fichero que
  # genera le esta esperando al usuario.
  @spec render() :: {:ok, binary()} | {:error, binary()}
  def render do
    contents = build()

    case Toml.decode(contents) do
      {:ok, _parsed} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, "el esqueleto generado no parsea: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec build() :: binary()
  def build do
    """
    # candil.toml — la configuracion de Candil.
    #
    # Este fichero lo escribe `candil init` y sale de
    # `Candil.Config.Template`, que lo genera a partir del schema: si anades
    # una clave nueva a Candil, aparece aqui sin que nadie tenga que acordarse
    # de updating this text.
    #
    # Todo esta comentado a proposito. El fichero que `init` deja es valido y no
    # hace nada, y `candil models list` lo dice con un enlace a este sitio.
    # Descomenta lo que necesites seccion a seccion.
    #
    # ── general ────────────────────────────────────────────────────────────
    #
    # Donde viven los datos, los logs y el consumidor por defecto.
    # [general]
    #   # El directorio de trabajo: binarios, fuentes, checkpoints.
    #   # `candil doctor --fix` lo crea si falta.
    #   data_dir         = "~/.candil"
    #
    #   # A donde van los logs. Puede ser cualquier sitio; no tiene por que
    #   # estar dentro de data_dir, y `doctor --fix` reporta donde escribio de
    #   # verdad en vez de donde se supone que deberia.
    #   log_dir          = "~/.candil/logs"
    #
    #   # Que consumidor usan las peticiones que no dicen cual.
    #   default_consumer = "default"

    # ── engine.<nombre> ─────────────────────────────────────────────────────
    #
    # Un engine es como se arranca un modelo. El que uses depende de lo que
    # tengas: `llama_cpp` es lo habitual en local.
    #
    # [engine.llama_cpp]
    #   # Donde esta o donde se instalara el binario. Si `install.strategy` es
    #   # "source", Candil lo compila; si es "precompiled", lo descarga.
    #   binary    = "~/.candil/llm/bin/llama-server"
    #   host      = "127.0.0.1"
    #
    #   # El puerto base. Cada modelo suma a partir de aqui, y `doctor` avisa
    #   # si alguno esta ocupado por otro proceso.
    #   base_port = 10000
    #
    #   # El sha256 del zip que se descarga, si la estrategia es "precompiled":
    #   # el archivo acaba ejecutandose, asi que si esta puesto se verifica al
    #   # bajar y una release que haya cambiado no pasa. Opcional — GitHub no
    #   # promete el digest como HuggingFace, y esto es escrito a mano.
    #   checksum_sha256 = "0000…"
    #
    #   # Como CONSEGUIR el binario.
    #   [engine.llama_cpp.install]
    #   #   "source"     = compilar; necesitas cmake, ninja y las cabeceras de
    #   #                  CUDA si quieres GPU. Tarda.
    #   #   "precompiled"= bajar un binario ya hecho. Rapido, pero no lleva los
    #   #                  flags de tu hardware: una RTX 5080 (Blackwell)
    #   #                  necesita 120a junto con MXFP4 y NVFP4, y un binario
    #   #                  generico no los trae.
    #   #   "none"       = ya lo tienes tu.
    #   strategy  = "source"
    #   repo      = "https://github.com/ggml-org/llama.cpp"
    #   ref       = "b4561"
    #   src_dir   = "~/.candil/src/llama.cpp"
    #   build_dir = "~/.candil/build/llama.cpp"
    #   generator = "ninja"
    #   dir       = "~/.candil/llm/bin"
    #   binaries  = ["llama-server", "llama-cli"]
    #
    #   # Los flags de TU hardware. Candil no anade ninguno por su cuenta, y no
    #   # debe empezar a hacerlo: quien sabe el hardware es quien escribe esto.
    #   #
    #   # macOS/Metal: GGML_METAL_* y -mcpu=native.
    #   # Sin GPU: quita los -DGGML_CUDA* y deja -DGGML_NATIVE=ON.
    #   cmake_args = [
    #     "-DCMAKE_BUILD_TYPE=Release",
    #     "-DCMAKE_CUDA_ARCHITECTURES=120a",
    #     "-DGGML_CUDA=ON", "-DGGML_CUDA_FA=ON",
    #     "-DGGML_CUDA_MMQ_MXFP4=ON", "-DGGML_CUDA_MMQ_NVFP4=ON",
    #     "-DGGML_NATIVE=ON"
    #   ]

    # ── model.<alias> ───────────────────────────────────────────────────────
    #
    # Un modelo. El alias es lo que escribes en `candil run <alias>`.
    #
    # [model.coder]
    #   type         = "local"     # "local" o "remote"
    #   engine       = "llama_cpp" # el engine de arriba
    #   context_size = 131072
    #   port         = 9999        # el puerto EXACTO; si lo omites, del base_port
    #
    #   # QUE ENDPOINTS sirve este destino. Solo tres: chat, completion,
    #   # embeddings. Es lo que decide si se le puede pedir una peticion.
    #   usage        = ["chat", "completion"]
    #
    #   # PARA QUE es bueno, que es otra pregunta. Si no lo dices, no se inventa:
    #   # un modelo sin capabilities no se considera bueno para nada en
    #   # particular, que es distinto de considerarlo bueno para todo.
    #   capabilities = ["code", "reasoning"]
    #   tags         = ["gpu", "moe", "code"]
    #
    #   # EXCLUSIVO: ¿este destino se puede usar a la vez que otro?
    #   #
    #   # false (defecto) — no. Dos peticiones al mismo destino van en
    #   # paralelo, porque no hay nada que las estorbe. Una API, tipicamente.
    #   # Asi el camino caliente no toca la cola, y no hay cola que tocar.
    #   #
    #   # true — si. Lo tiene uno y no caben dos. Un modelo en una GPU es el
    #   # caso: mientras esta cargado, la segunda peticion espera su turno.
    #   #
    #   # No hay un interruptor global a proposito: con tres APIs y una GPU
    #   # habria que elegir un modo para los cuatro, y cualquier eleccion es
    #   # mala para tres. Cada destino declara lo suyo y solo.
    #   exclusive    = false
    #
    #   # QUE SABE HACER ESTE MODELO, en una frase y con tus palabras. No es la
    #   # carta de presentación ni el nombre del fichero: es el texto que la
    #   # capa `:embedding` del router compara con tu prompt, y es lo UNICO
    #   # que tiene para hacerlo.
    #   #
    #   # Sin ella, esa capa devuelve `:miss`: no compara con el alias ni con
    #   # el nombre del .gguf, porque un 0 de similitud sacado de un texto que
    #   # nadie escribió no es una medida. Ponla en el idioma en el que te van
    #   # a preguntar, que el embedder tambien tiene su idioma.
    #   description  = "escribe, explica y arregla código en Elixir y Python"
    #
    #   # Cuantas capas van a la GPU. -1 = "las que quepan" (lo que hace
    #   # llama-server cuando no le fijas nada), 0 = CPU entera. `candil run
    #   # --cpu` pone este campo a 0; si lo que quieres es apagar la GPU un
    #   # rato, esto. No lo pongas tambien dentro de `model_args`: allí Candil
    #   # lo saca y lo pasa aquí, porque dos sitios para el mismo número es
    #   # como llama-server se queja de "already set by user".
    #   gpu_layers   = -1
    #
    #   # VRAM que ocupa el modelo en MB (opcional, y casi nunca hace falta).
    #   #
    #   # La reserva que Candil lleva es SIEMPRE el peso MEDIDO con
    #   # `llama-fit-params` en el momento de arrancar, no este numero. Asi que
    #   # esto no dice cuanto ocupa el modelo: dice cuanto ocupaba la ultima
    #   # vez que se arranco, y solo sirve como estimacion previa para que un
    #   # segundo arranque que no cabe falle pronto en vez de a los 4 s.
    #   #
    #   # Y el numero no es estable: el MISMO modelo medido el 2026-10-21 dio
    #   # 795 MiB con la GPU ocupada, 7978 MiB con la GPU medio libre y 10452
    #   # MiB con la GPU libre. Lo que cambia es quantas capas cabe recorta
    #   # llama.cpp, que depende de la memoria libre del instante. Por eso
    #   # dejarlo a mano es una forma de quedarse con un numero viejo, y la
    #   # reserva lo corrige igual.
    #   vram_mb      = 13000
    #
    #   # Tokens de respuesta que se piden como maximo (opcional). El default
    #   # global son 4096, y con eso casi todo modelo contesta de sobra.
    #   #
    #   # **El razonamiento cuenta dentro del maximo.** Un modelo que razona
    #   # (su `reasoning_content` va en la misma respuesta) se puede quedar sin
    #   #(tokens para la RESPUESTA y devolver un `content: ""` que parece una
    #   # respuesta. Medido el 2026-10-22 con un modelo que razona: con 512
    #   #tokens la respuesta vino vacia; con 2000, vino de verdad.
    #   #
    #   # Ponlo cuando el modelo tenga un presupuesto de pensamiento grande (el
    #   # `--reasoning-budget` de llama-server) o cuando writes codigo largo.
    #   max_tokens  = 16384
    #
    #   # Los flags que se pasan a llama-server.
    #   #
    #   # OJO: un flag y su valor son DOS elementos. Se pasa la lista al argv
    #   # sin partirla, asi que "--n-gpu-layers -1" llega como un flag de 19
    #   # caracteres que llama.cpp no reconoce.
    #   model_args   = ["--n-gpu-layers", "-1", "--cache-type-k", "q8_0",
    #                   "--jinja", "--temp", "0.7"]
    #
    #   # De donde sale el .gguf. Sin esto el modelo no se descarga nunca.
    #   [model.coder.source]
    #   kind = "huggingface"   # o "local"
    #   repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
    #   file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
    #   dest = "~/models/gguf"   # `~` no se expande dentro de model_args

    # ── router ──────────────────────────────────────────────────────────────
    #
    # Las cuatro capas del enrutado, y los dos NAMES que encienden las que
    # faltaban. Los dos son `nil` por omision, y no es un descuido: sin
    # clasificador ni embedder registrados, las capas `:llm` y `:embedding` no
    # existen y el router baja a la siguiente. Un nombre que no este
    # registrado tampoco es un error de arranque —la capa simplemente no esta—
    # asi que pon aqui el NOMBRE con el que lo registraste, no el modulo.
    #
    # [router]
    #   # La cuarta capa: un LLM que dice que tan dificil es el prompt. Apagada
    #   # por defecto, porque cuesta una inferencia y ahorra muchisimas menos.
    #   enable_llm_classifier = false
    #   classifier             = "etiquetas"
    #
    #   # El embedder de la capa `:embedding`. Tambien `nil` por omision, y por
    #   # el mismo motivo caro: uno por defecto decidiria, para todo el mundo y
    #   # sin que nadie lo pidiera, en que se calculan las distancias.
    #   embedder = "bge"
    #
    #   # La confianza con la que la capa `:llm` se compara con el umbral, tal
    #   # cual la da el clasificador. No se normaliza aqui.
    #   confidence_threshold = 0.70
    #
    #   # El umbral de la capa `:embedding`, con el embedder de este fichero.
    #   #
    #   # **Depende del embedder**: no es una constante de Candil. El defecto
    #   # (0.35) se midio con 106 peticiones reales en cuatro idiomas: la capa
    #   # estatica resolvia el 30% con acierto perfecto, frente al 10% que
    #   # resolvia el 0.55 heredado de otro modelo de embeddings. Si cambias de
    #   # embedder, este numero es el primero que hay que recalibrar.
    #   embedding_threshold  = 0.35
    #   # Las reglas de palabras van aparte, en [router.rules], y el vocabulario
    #   # es tuyo —el de las preguntas que te hacen de verdad. Sin esto la capa
    #   # usa un vocabulario ingles de reserva que no casa con tus prompts.
    #   #
    #   # Se indexa por ALIAS, no por categoria: escribir el alias es anadirlo.
    #   # La forma de antes pedia configurar dos cosas —la categoria y a que
    #   # alias iba— y una de las dos estaba en el codigo.
    #   #
    #   #   [router.rules.coder]
    #   #   words = ["arregla", "bug", "compila", "test", "refactor"]
    #   #
    #   #   [router.rules.verificador]
    #   #   words = ["analiza", "compara", "demuestra", "por que"]
    #   #
    #   # Ojo al punto por punto: una peticion tiene que casar con una fraccion
    #   # de TU lista. Con tres palabras hacen falta dos; con veinte, cuatro. Un
    #   # vocabulario mas rico hace la capa MAS DIFICIL, no mas facil.
    #
    # ── provider.<nombre> ───────────────────────────────────────────────────
    #
    # Para modelos remotos. La clave va en el entorno; el nombre de la variable
    # se declara aqui, no el secreto.
    #
    # [provider.openai]
    #   type = "openai"
    #   base_url = "https://api.openai.com"
    #   # El NOMBRE de la variable, no el secreto. Sin esto, un provider
    #   # openai o anthropic no valida.
    #   api_key_env = "OPENAI_API_KEY"

    # Para registrar un modelo de verdad tienes dos caminos:
    #
    #   A. editar este fichero: descomenta [model.<alias>] y su [.source],
    #      y luego `candil models pull <alias>` para bajar el .gguf.
    #
    #   B. copiar este fichero a tu sitio y descomentar lo que necesites:
    #        cp docs/05-cli/config/candil.toml ~/.config/candil/candil.toml
    #
    # Y en cualquier momento, `candil doctor` te dice que falta.

    # ── consumer.<nombre> ───────────────────────────────────────────────────
    #
    # Quien pregunta. Cada uno puede tener sus propios modelos y su propia
    # politica de contexto, y el router elige entre los suyos: un consumer
    # cuya lista no incluye el modelo que le ha tocado se queda sin respuesta
    # en vez de hablar con el que no era.
    #
    # [consumer.default]
    #   # Modelos que le sirven a este, en orden de preferencia. Si no pones
    #   # nada, se usa `default_consumer` de [general] y su model_default.
    #   models = ["coder", "verifier"]
    #
    #   # Que pasa cuando el historial no cabe en la ventana del modelo.
    #   #   "strict"    -> error. No recorta nunca, y no degrada nunca.
    #   #   "compact"   -> recorta los turnos viejos.
    #   #   "summarize" -> los resume. Si el resumen falla, degrada a compact.
    #   context_policy = "strict"
    #
    # Con esto, `candil route pin <model>` y `candil route ask --consumer`
    # tienen sobre que trabajar.
    """
  end
end
