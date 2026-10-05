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

  @doc """
  The template, as a string.
  """
  @spec render() :: binary()
  def render do
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
    #   # Para que aparezcan en "what do I use this for": chat, code,
    #   # completion, reasoning, embeddings, vision.
    #   usage        = ["chat", "code"]
    #   tags         = ["gpu", "moe", "code"]
    #
    #   # Cuantas capas van a la GPU. -1 = "las que quepan" (lo que hace
    #   # llama-server cuando no le fijas nada), 0 = CPU entera. `candil run
    #   # --cpu` pone este campo a 0; si lo que quieres es apagar la GPU un
    #   # rato, esto. No lo pongas tambien dentro de `model_args`: allí Candil
    #   # lo saca y lo pasa aquí, porque dos sitios para el mismo número es
    #   # como llama-server se queja de "already set by user".
    #   gpu_layers   = -1
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

    # ── provider.<nombre> ───────────────────────────────────────────────────
    #
    # Para modelos remotos. La clave va en el entorno; el nombre de la variable
    # se declara aqui, no el secreto.
    #
    # [provider.openai]
    #   type = "openai_compat"
    #   base_url = "https://api.openai.com/v1"
    #   key_env = "OPENAI_API_KEY"

    # Para registrar un modelo de verdad tienes dos caminos:
    #
    #   A. editar este fichero: descomenta [model.<alias>] y su [.source],
    #      y luego `candil models pull <alias>` para bajar el .gguf.
    #
    #   B. partir de un ejemplo que ya funciona:
    #        cp "proyecto 4.0/candil.toml" ~/.config/candil/candil.toml
    #      Ese trae siete modelos declarados, con sus flags.
    #
    # Y en cualquier momento, `candil doctor` te dice que falta.
    """
  end
end
