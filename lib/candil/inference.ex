defmodule Candil.Inference do
  @moduledoc """
  Inference execution for Candil.

  Handles chat completions and embeddings for both local engines and remote
  providers. Normalises the request/response format across the supported
  provider APIs (OpenAI, Anthropic, Ollama, OpenAI-compatible).

  ## Message format

  All messages are plain maps with `:role` and `:content` string keys:

      %{role: "system", content: "You are a helpful assistant."}
      %{role: "user", content: "Hello!"}
      %{role: "assistant", content: "Hi there!"}

  ## Response format

  All chat functions return a `response()` map:

      %{
        content: "Hello, how can I help?",
        role: "assistant",
        model: "llama-3-8b",
        finish_reason: "stop",
        usage: %{prompt_tokens: 12, completion_tokens: 8, total_tokens: 20}
      }

  ## El turno se toma aqui, y no en quien llama

  La cola de `Candil.Policy` se toma en este modulo, que es donde se habla con
  el destino de verdad, y no en el camino de entrada. Antes se tomaba en el
  gateway, y eso hacia que la exclusividad fuera una propiedad del **camino**:
  quien llamaba a `chat_local/3` desde Elixir —que es la API publica de una
  libreria— entraba a un destino `exclusive = true` sin hacer cola. Medido: 12
  peticiones simultaneas a un destino exclusivo, 0 esperas por este camino y 11
  por el del gateway, con el mismo destino y la misma carga.

  Que sea una propiedad del destino y no de quien llame es toda la diferencia
  entre una garantia y un deseo, y el coste de pagarla es **1,45 microsegundos**
  por llamada —medido, 200.000 iteraciones— contra inferencias de miles de
  milisegundos. En un destino no exclusivo no se arranca ningun proceso: es el
  camino caliente de `Candil.Policy`, que sigue siendo lo que su `@moduledoc`
  promete.

  Y es seguro que lo envuelvan dos: `Policy.run/3` es idempotente por proceso y
  destino, asi que el gateway que ya tiene el turno no se encola otra vez.

  """

  alias Candil.{Error, Model, Policy, Provider, Store}

  alias Candil.Inference.{Chat, Embeddings}

  @type message :: %{required(:role) => binary(), required(:content) => binary()}

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type response :: %{
          content: binary(),
          # El razonamiento, si el servidor lo manda en `reasoning_content`.
          # `nil` cuando el modelo no razona, que es lo normal y no un fallo.
          # Ver `Candil.Inference.Chat.parse_openai_response/1`.
          reasoning: binary() | nil,
          role: binary(),
          model: binary(),
          finish_reason: binary() | nil,
          usage: usage() | nil
        }

  @type embed_response :: [[float()]]

  @doc """
  Runs a chat completion against a local llama-server.

  The engine must be running and healthy. Resolves the server URL from the
  registry via the model alias.

  ## Options

    * `:temperature` — sampling temperature 0.0–2.0 (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences (default: `[]`)
    * `:system` — system prompt string (prepended to messages if set)

  """
  @spec chat_local(atom(), [message()], keyword()) :: {:ok, response()} | {:error, Error.t()}
  def chat_local(model_alias, messages, opts \\ []) do
    with {:ok, model} <- Store.get_model(model_alias),
         false <- model.type == :remote,
         true <- :chat in model.usage || :completion in model.usage do
      # El turno envuelve **la llamada entera**, no el dispatch: lo que se
      # ordena es quien esta usando la GPU, y eso dura lo que dura la peticion.
      con_turno(model_alias, fn -> Chat.do_chat_local(model_alias, messages, opts) end)
    else
      {:error, :not_found} ->
        {:error, Error.model_not_found(model_alias)}

      true ->
        {:error, Error.invalid_request("Model #{model_alias} is remote, use chat_remote/4")}

      false ->
        {:error, Error.invalid_request("Model #{model_alias} does not support chat")}
    end
  end

  # `Policy.run/3` devuelve `{:ok, fun.()}` y `fun` ya devuelve `{:ok, respuesta}`.
  # Sin quitar la capa de aqui sale `{:ok, {:ok, respuesta}}`, que es un 200 con
  # `content: ""` que parece respuesta.
  defp unwrap({:ok, resultado}), do: resultado
  defp unwrap({:error, reason}), do: {:error, reason}

  # Los cuatro caminos de inferencia toman turno, **tambien los remotos**: si
  # `exclusive` es una propiedad del destino —y lo es desde que el turno se toma
  # aqui y no en quien llama— un destino remoto marcado como exclusivo tiene que
  # serializar igual. Dejar fuera los remotos haria la garantia media, que es
  # peor que no hacerla: porque alguien puede leer «exclusive» y no mirar si el
  # modelo es local o remoto.
  defp con_turno(model_alias, fun), do: unwrap(Policy.run(model_alias, fun))

  @doc """
  Runs a chat completion against a remote provider.

  Dispatches to the appropriate provider module based on `provider.type`.

  ## Options

  Same as `chat_local/3`.
  """
  @spec chat_remote(Model.t(), Provider.t(), [message()], keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def chat_remote(%Model{} = model, %Provider{} = provider, messages, opts) do
    con_turno(model.alias, fn -> Chat.do_chat_remote(model, provider, messages, opts) end)
  end

  @doc """
  Generates embeddings for a list of texts against a local engine.

  The model must have `:embeddings` in its `usage` list.
  """
  @spec embed_local(atom(), [binary()], keyword()) ::
          {:ok, embed_response()} | {:error, Error.t()}
  def embed_local(model_alias, texts, _opts \\ []) do
    with {:ok, model} <- Store.get_model(model_alias),
         false <- model.type == :remote,
         true <- :embeddings in model.usage do
      # Mismo turno y mismo motivo que en `chat_local/3`: un embedder local
      # tambien es una GPU, y compartiendola con una inferencia lo que se
      # rompe es la GPU, no el embedder.
      con_turno(model_alias, fn -> Embeddings.do_embed_local(model_alias, texts) end)
    else
      {:error, :not_found} ->
        {:error, Error.model_not_found(model_alias)}

      true ->
        {:error, Error.invalid_request("Model #{model_alias} is remote, use embed_remote/4")}

      false ->
        {:error, Error.invalid_request("Model #{model_alias} does not support embeddings")}
    end
  end

  @doc """
  Generates embeddings for a list of texts against a remote provider.
  """
  @spec embed_remote(Model.t(), Provider.t(), [binary()], keyword()) ::
          {:ok, embed_response()} | {:error, Error.t()}
  def embed_remote(%Model{} = model, %Provider{type: :ollama} = provider, texts, opts) do
    con_turno(model.alias, fn -> Embeddings.do_embed_remote(model, provider, texts, opts) end)
  end

  def embed_remote(%Model{} = model, %Provider{} = provider, texts, opts) do
    con_turno(model.alias, fn -> Embeddings.do_embed_remote(model, provider, texts, opts) end)
  end
end
