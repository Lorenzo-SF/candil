defmodule Candil.Gateway.Handlers.ChatCompletions do
  @moduledoc """
  `POST /v1/chat/completions` y `POST /c/<consumer>/v1/chat/completions`.

  ## El `"auto"` es opt-in, a proposito

  Un `"model": "auto"` pasa por el router. Un modelo nombrado **se salta el
  router entero**, porque quien lo nombra ya ha decidido. Un router del que no se
  puede salir es un router cuyos errores no se pueden esquivar, y en un cliente
  de escritorio eso es unCutting de la sesion entero.

  ## Donde entra la politica

  La inferencia va **dentro de `Policy.run/3`**, y no antes ni despues. Es la
  unica razon por la que la cola existe: dos peticiones al mismo destino
  exclusivo tienen que serializarse, y eso solo pasa si el turno abarca la
  llamada entera. Un destino que no es exclusivo **no arranca ninguna cola** —el
  defecto es `false`— y por eso esto no cuesta nada en el camino normal.

  Y lo que **no** hay aqui, a proposito: ninguna evaluacion de la respuesta, y
  ningun estado de sesion. Un servidor HTTP devuelve lo que le devolvieron a
  quien lo pidio, y la correlacion la da el propio proceso de la peticion. Lo
  que hace falta es no inventar un segundo mecanismo que ya existe.
  """

  @behaviour Plug

  alias Candil.{Error, Gateway, Inference, Policy, Router, Store}
  alias Candil.Gateway.Handlers

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, context) do
    conn = Plug.Conn.fetch_query_params(conn)

    case handle(conn, context) do
      {:ok, payload} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(payload))

      {:error, reason} ->
        {:error, body} = Gateway.error_body(reason)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status_for(reason), Jason.encode!(body))
    end
  end

  defp handle(conn, context) do
    with {:ok, body} <- read_json(conn),
         {:ok, messages} <- messages(body),
         {:ok, capa} <- capa_forzada(conn, body),
         {:ok, model_alias, decision} <- resolve(body["model"], messages, context, capa) do
      with {:ok, response} <- infer(model_alias, messages, body),
           {:ok, model} <- fetch(model_alias) do
        {:ok, envelope(response, model_alias, decision, model)}
      end
    end
  end

  # ── forzar la capa ───────────────────────────────────────────────────────

  # Que un cliente diga **que capa quiere**, sin tocar la configuracion global.
  #
  # Dos caminos por quienes los usan: la **cabecera `X-Candil-Strategy`** es lo
  # unico que se puede mandar sin que el cuerpo deje de ser un cuerpo OpenAI —
  # que es lo que aceptan opencode y los demas—, y el **campo `candil.strategy`**
  # es para quien solo controla el JSON. Si vienen los dos, gana el cuerpo: quien
  # manda el cuerpo entero esta mas cerca de la peticion.
  #
  # Un nombre desconocido es un **400**, no un silencio. Quien pide una capa y
  # recibe otra no se entera nunca, y un enrutado que se equivoca sin decirlo es
  # peor que uno que se equivoca diciendo.
  @capas ~w(rule embedding llm)

  defp capa_forzada(conn, body) do
    # El cuerpo gana sobre la cabecera: quien manda el cuerpo entero esta mas
    # cerca de la peticion que quien pone una cabecera por encima.
    cuerpo = get_in(body, ["candil", "strategy"])
    cabecera = conn |> Plug.Conn.get_req_header("x-candil-strategy") |> List.first()
    cruda = if is_binary(cuerpo), do: cuerpo, else: cabecera

    # SIEMPRE `{:ok, capa | nil}`. Devolver un `:ok` a secas haria que el
    # `with` de arriba no casara —`{:ok, capa} <- :ok` es `false`— y saliera
    # sin decidir: un 500 en vez de una respuesta. Un helper que puede devolver
    # dos formas de lo mismo es un helper que alguien va a usar mal.
    case cruda do
      nil ->
        {:ok, nil}

      valor when is_binary(valor) ->
        capa = valor |> String.trim() |> String.downcase()

        if capa in @capas do
          {:ok, String.to_existing_atom(capa)}
        else
          {:error,
           Error.invalid_request(
             "unknown candil strategy #{inspect(valor)}. One of: #{Enum.join(@capas, ", ")}."
           )}
        end

      _otra ->
        {:error, Error.invalid_request("`candil.strategy` has to be a string")}
    end
  end

  # ── quien contesta ─────────────────────────────────────────────────────────

  defp resolve("auto", messages, context, capa) do
    opts = context.opts[:route] || []
    opts = if capa, do: opts ++ [force_strategy: capa], else: opts

    case Router.route(messages, opts ++ [consumer: context.consumer]) do
      {:ok, decision} -> {:ok, decision.model_alias, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve(nil, _messages, _context, _capa),
    do: {:error, Error.invalid_request("the request has no `model`; use a name or \"auto\"")}

  defp resolve(name, _messages, _context, _capa) when is_binary(name) do
    case existing_alias(name) do
      nil -> {:error, Error.invalid_request("no model named #{inspect(name)} is registered")}
      alias_atom -> {:ok, alias_atom, nil}
    end
  end

  # `to_existing_atom/1` y no `to_atom/1`: el nombre viene del cuerpo de una
  # peticion, y `to_atom` CREA el atomo. Un `"model": "inventado-N"` por
  # peticion es memoria que no se libera nunca, y el binario crece.
  defp existing_alias(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # ── la llamada ─────────────────────────────────────────────────────────────

  # El turno envuelve a la llamada ENTERA. Ponerlo solo alrededor del dispatch
  # dejaria fuera la espera a que el motor este listo, que es justo la parte que
  # dos peticiones simultaneas se pelean.
  #
  # Y se **desenvuelve**: `Policy.run/3` devuelve `{:ok, fun.()}`, y `fun` ya
  # devuelve `{:ok, respuesta}`. Sin quitar la capa de aqui sale
  # `{:ok, {:ok, respuesta}}`, `content/1` recibe una tupla en vez de un mapa, y
  # cae en su clausula deelnada — **un 200 con `content: ""` que parece
  # respuesta**. Cuesta verlo porque el codigo de estado es correcto.
  defp infer(alias_atom, messages, body) do
    opts = inference_opts(body)

    case Policy.run(alias_atom, fn -> dispatch(alias_atom, messages, opts) end) do
      {:ok, resultado} -> resultado
      otro -> otro
    end
  end

  defp dispatch(alias_atom, messages, opts) do
    with {:ok, model} <- fetch(alias_atom) do
      case model.type do
        :remote ->
          case Store.get_provider(model.provider) do
            {:ok, provider} -> Inference.chat_remote(model, provider, messages, opts)
            {:error, :not_found} -> {:error, Error.provider_not_found(model.provider)}
          end

        _local ->
          Inference.chat_local(alias_atom, messages, opts)
      end
    end
  end

  defp fetch(alias_atom) do
    case Store.get_model(alias_atom) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> {:error, Error.model_not_found(alias_atom)}
    end
  end

  # ── el sobre ──────────────────────────────────────────────────────────────

  defp envelope(response, alias_atom, decision, model) do
    base =
      Gateway.chat_completion(
        "chatcmpl-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
        content(response)
      )

    base
    |> Map.put(:model, to_string(alias_atom))
    |> Map.put(:created, System.system_time(:second))
    |> Map.put(:usage, usage(response))
    |> Map.put(:candil, meta(decision, model))
  end

  # Lo que enrutó Candil, para el cliente que quiera saberlo. **No es la
  # respuesta OpenAI**: va aparte, y un cliente que no lo conesca lo ignora.
  defp meta(nil, _model), do: %{strategy: nil, routed: false}

  defp meta(decision, model),
    do: %{
      strategy: decision.strategy,
      score: decision.score,
      score_kind: kind(model),
      routed: true
    }

  defp kind(%{type: :remote}), do: "remote"
  defp kind(_), do: "local"

  defp content(%{content: content}) when is_binary(content), do: content
  defp content(_), do: ""

  defp usage(%{usage: usage}) when is_map(usage), do: usage
  defp usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  # ── la entrada ─────────────────────────────────────────────────────────────

  defp read_json(conn) do
    case Handlers.read_json(conn) do
      {:ok, body} -> {:ok, body}
      {:error, why} -> {:error, Error.invalid_request(why)}
    end
  end

  defp messages(%{"messages" => messages}) when is_list(messages) do
    if Enum.all?(messages, &is_map/1),
      do: {:ok, messages},
      else: {:error, Error.invalid_request("`messages` must be a list of objects")}
  end

  defp messages(_), do: {:error, Error.invalid_request("`messages` is missing")}

  # Lo que se pasa tal cual al modelo. **No se inventa aqui ningun filtro**: lo
  # que no se sabe, no se toca. Y `max_tokens` en `nil` es "no lo digas", que
  # es distinto de "digalo en cero".
  defp inference_opts(body) do
    []
    |> put_opt(:max_tokens, body["max_tokens"])
    |> put_opt(:temperature, body["temperature"])
    |> put_opt(:top_p, body["top_p"])
    |> put_opt(:stop, body["stop"])
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp status_for(:rate_limited), do: 429
  defp status_for(%Error{reason: :context_overflow}), do: 400
  defp status_for(%Error{reason: :invalid_request}), do: 400
  defp status_for(%Error{reason: :model_not_found}), do: 404
  defp status_for(%Error{reason: :provider_not_found}), do: 404
  defp status_for(%Error{reason: :auth_error}), do: 401
  defp status_for(_reason), do: 500
end
