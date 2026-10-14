defmodule Candil.HTTP.Client do
  @moduledoc false

  alias Apero.Http, as: AperoHTTP
  alias Candil.Error

  @type response :: %{status: pos_integer(), body: any(), headers: list()}

  @spec get(binary(), [{binary(), binary()}], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(url, headers \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)

    case AperoHTTP.get(url, headers, receive_timeout: timeout) do
      {:ok, %AperoHTTP.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: body}}

      {:ok, %AperoHTTP.Response{status: 429, body: body}} ->
        {:error, Error.rate_limited(body["retry_after"])}

      {:ok, %AperoHTTP.Response{status: status, body: body}} ->
        {:error, Error.http_error(status, body)}

      {:error, %AperoHTTP.Error{reason: :timeout}} ->
        {:error, Error.timeout(%{url: url})}

      {:error, %AperoHTTP.Error{reason: reason}} ->
        {:error, Error.wrap(reason)}
    end
  end

  def do_post_json(url, body, headers, timeout) do
    case AperoHTTP.post(url, body, headers, receive_timeout: timeout) do
      {:ok, %AperoHTTP.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, %AperoHTTP.Error{} = error} ->
        {:error, error}
    end
  end

  def do_post_streaming(url, body, headers, timeout, streaming_opts) do
    user_callback = Keyword.get(streaming_opts, :into, &default_stream_callback/2)

    # El contrato de `Finch.stream/5` —el adapter de verdad— es:
    #
    #     {:status, status}  {:headers, headers}  {:data, data}  :done
    #
    # **`done` es un atomo suelto.** Y aqui se perdia: el `case` solo matcheaba
    # `{:done, _}`, que Finch no emite nunca, asi que `:done` caia en el brazo
    # de abajo y `user_callback` no se enteraba de que se habia acabado. Quien
    # esperaba no recibia el final y se comia el timeout entero —150 s con los
    # valores por defecto— y luego devolvia `:ok`, que es indistinguible de
    # que haya ido bien. Medido: 600 ms en los tests, que es justo su timeout.
    stream_fun = fn entry, acc ->
      case entry do
        {:data, _data} ->
          user_callback.(entry, acc)

        :done ->
          # Se avisa **antes** de parar: quien escucha necesita saber que
          # acabo, no solo que dejo de llegar cosa. Y se avisa con la misma
          # forma que emite Finch —`:done` a pelo— porque el callback de
          # Candil (`receive_inbox/2`) la espera asi. Pasarle `{:done, _}`
          # hacia que no matcheara ninguna clausula y el Task moriria en
          # silencio, que es justo el fallo que esto arregla.
          user_callback.(:done, acc)

        # `{:done, _}` no lo emite Finch, pero `default_stream_callback/2` lo
        # aceptaba: se acepta aqui para no romper un callback escrito con esa
        # forma, y no cuesta nada.
        {:done, _} ->
          user_callback.(:done, acc)

        _ ->
          {:cont, acc}
      end
    end

    case AperoHTTP.stream(:post, url, body, headers, [], stream_fun, receive_timeout: timeout) do
      {:ok, acc} ->
        {:ok, acc}

      {:error, %AperoHTTP.Error{reason: :timeout}} ->
        {:error, Error.timeout()}

      {:error, %AperoHTTP.Error{reason: reason}} ->
        {:error, Error.wrap(reason)}
    end
  end

  # El callback devuelve **el acumulador nuevo**, no una tupla: `Finch.stream/5`
  # lo envuelve en `{:cont, _}` por dentro, asi que devolver `{:cont, acc}`
  # acababa con un acumulador `{:cont, [datos]}` anidado una vez por chunk.
  def default_stream_callback({:data, data}, acc), do: [data | acc]

  def default_stream_callback(:done, acc) do
    # Se devuelve el acumulador, no `{:halt, []}`: el callback no puede parar el
    # stream —`Finch.stream/5` siempre contesta `{:cont, _}` por dentro— y lo
    # que devuelve este callback es el acumulador de Finch, que no es de este
    # modulo para vaciarlo.
    acc
  end

  def breaker_name(url) do
    host = URI.parse(url).host
    existing_atom(host) || :default_breaker
  rescue
    _ -> :default_breaker
  end

  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  @spec wrap_error(term()) :: {:ok, response()} | {:error, Error.t()}
  def wrap_error({:ok, %{status: status} = response}) when status in 200..299 do
    {:ok, response}
  end

  def wrap_error({:ok, %{status: 429, body: body}}) do
    {:error, Error.rate_limited(body["retry_after"])}
  end

  def wrap_error({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body)}
  end

  def wrap_error({:error, %{reason: :timeout}}) do
    {:error, Error.timeout()}
  end

  def wrap_error({:error, reason}) do
    {:error, Error.wrap(reason)}
  end

  def wrap_reason(%{reason: :timeout}), do: Error.timeout()
  def wrap_reason(reason), do: Error.wrap(reason)
end
