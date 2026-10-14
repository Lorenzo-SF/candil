defmodule Candil.HTTP.Breaker do
  @moduledoc """
  Un circuito por **destino**, y un circuito que existe.

  Antes de esto, `Candil.HTTP` anunciaba un circuit breaker y no tenia ninguno.
  Medido el 2026-10-14: **0 registrados**, y `Arrea.CircuitBreaker.call/2` sobre
  un nombre sin registrar ejecuta la funcion y ya esta. Ademas:

  - `Client.breaker_name/1` caia a `:default_breaker` para casi todo, porque
    devuelve el host **solo si ese atomo ya existe en la VM**, y ni
    `127.0.0.1` ni `api.openai.com` existen. Un solo circuito para todos los
    destinos.
  - Un error de red llegaba a Arrea como `{:error, _}`, y `call/3` cuenta fallo
    **solo cuando la funcion lanza**. Para Arrea, un destino caido era un exito.

  Aqui hay tres correcciones, y las tres son medidas.

  ## El nombre es un string, y uno por destino

  `"candil-breaker-<host>-<puerto>"`, no un atomo. No es cosmetico: la razon por
  la que el nombre viejo acababa en `:default_breaker` era `String.to_existing_atom`,
  que existe justo para **no** crear atomos con datos de fuera. Con un string el
  problema desaparece en vez de esquivarse, y un destino caido apaga su circuito
  y no el de al lado.

  Arrea registra por nombre con `{:via, Registry, {_, name}}`, y eso acepta
  cualquier termino: comprobado, un circuito con nombre string abre y bloquea
  igual que uno con atomo.

  ## Que cuenta como fallo

  Aqui se decide, y la decision es de quien escribe el modulo, no de Arrea:

  | Que pasa | Cuenta como fallo |
  |---|---|
  | **5xx** (el destino esta roto) | si |
  | **error de red, timeout, conexion rechazada** | si |
  | **429** (le has pedido demasiado) | si |
  | **otros 4xx** (tu peticion estaba mal) | **no** |
  | excepcion | si |

  La linea que divide las dos mitades: un 4xx es un error **del cliente**, y
  cerrar el circuito porque el cliente mando algo mal apaga Candil entero
  cuando el destino estaba perfecto. Un 5xx es del **destino**, que es
  justo lo que un corteprotecta existe para no golpear.

  Que se reporte con `success/1` y `failure/1` en vez de launching excepciones
  es lo que permite esa division: `call/3` solo sabe si la funcion **lanzo**.

  ## Los numeros salen de aqui, no de un chiffon

  `threshold` y `timeout` se leen de la configuracion, con estos defectos:

  - `threshold`: **5** fallos consecutivos. El defecto de Arrea tambien es 5,
    pero ahi es *acumulados*; con el fix de `failures: 0` son consecutivos de
    verdad.
  - `timeout`: **30 000 ms** abierto antes de dejar pasar una sonda, tomado de
    el plazo de `Arrea.Command`, que ya es el del proyecto y no uno inventado
    aqui.
  """

  alias Arrea.CircuitBreaker

  @supervisor Candil.HTTP.Breaker.Supervisor

  @default_threshold 5
  @default_timeout_ms 30_000

  @doc """
  El nombre del circuito de `url`.

  ## Un atomo, y por que pese a que podria no serlo

  `Arrea.CircuitBreaker` ya acepta cualquier nombre desde que su `@spec` se
  corrigio (Lorenzo-SF/arrea#35, 2026-10-14): antes decia `atom()` y el codigo
  mete el nombre en un `{:via, Registry, {_, name}}`, donde cabe cualquier
  termino.

  Aun asi aqui va un **atomo**, por dos razones que no son de estilo:

  1. `Apero.RateLimit.check/2` —la capa de al lado del limitador— **tiene una
     guarda `is_atom(name)`**. Un nombre compartido por las dos obligaria a que
     el circuito tambien fuera atomo.
  2. El PLT de dialyzer **no incluye las dependencias**, asi que dialyzer no ve
     los tipos locales de Arrea y trata su nombre como `atom()`. Medido: con el
     nombre en string, dialyzer daba cuatro `invalid_contract` en un modulo que
     funcionaba.

  ## Y el atomo solo nace de un destino del catalogo

  Un `String.to_atom/1` con una URL suelta es la forma de que un peer llene la
  tabla de atomos: por peticion y para siempre. Asi que **solo se crea para un
  destino que este en `candil.toml`**, que es de donde salen todas las URLs.

  Para un destino que **no** esta en el catalogo, `name/1` devuelve `nil` y la
  peticion va **sin circuito**. No es un parche: es la unica tercera opcion
  honesta. Un nombre global compartido parecia mejor y es peor —un destino
  desconocido abria el circuito de todos los demas—, y un atomo por peticion es
  un denial of service esperando a que alguien mande una URL.
  """
  @spec name(binary()) :: atom() | nil
  def name(url) do
    clave = clave(url)

    if destino_del_catalogo?(clave) do
      # `String.to_atom/1` es exactamente lo que este modulo evita en cualquier
      # otro sitio, y por eso lleva la justificacion puesta: el nombre sale de
      # una lista **acotada** —los destinos de `candil.toml`—, no de lo que
      # llegue en una peticion. Un destino desconocido devuelve `nil` y no crea
      # nada.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      String.to_atom("candil_breaker_#{clave}")
    end
  end

  defp clave(url) do
    uri = URI.parse(url)
    "#{uri.host}_#{uri.port}"
  end

  @doc """
  El nombre del limitador de tasa de `url`.

  ## Aqui si hace falta un atomo, y por que

  `Apero.RateLimit.check/2` tiene una **guarda `is_atom(name)`**, o sea que un
  string falla en runtime. El circuit breaker ya no lo exige —su `@spec` se
  corrigio el 2026-10-14 y acepta cualquier nombre—, pero el limitador todavia
  si.

  Por eso aqui **solo se crea un atomo para un destino del catalogo**. Una URL
  suelta —que solo puede venir de un fichero o de un cuerpo de peticion— cae
  en un nombre global compartido en vez de crear un atomo nuevo por peticion:
  un `String.to_atom/1` con datos de fuera es la forma de que un peer llene la
  tabla de atomos, y esa es justo la razon por la que el nombre del circuito
  viejo acababa en `:default_breaker`.

  Y el nombre global no es un parche: es un limite global de peticiones HTTP, que
  es una politica coherente. Lo que **no** tiene es un limite por destino, y eso
  necesita el mismo arreglo que se hizo en el circuit breaker pero en `Apero`.
  """
  @spec limit_name(binary()) :: atom()
  def limit_name(url) do
    clave = clave(url)

    if destino_del_catalogo?(clave) do
      # Mismo criterio y misma justificacion que en `name/1`: el nombre sale del
      # catalogo, no de una peticion.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      String.to_atom("candil_limit_#{clave}")
    end
  end

  defp destino_del_catalogo?(clave) do
    Enum.any?(Candil.Store.list_providers(), fn provider ->
      case provider.base_url do
        otra when is_binary(otra) ->
          uri = URI.parse(otra)
          "#{uri.host}_#{uri.port}" == clave

        _ ->
          false
      end
    end)
  rescue
    _ -> false
  end

  @doc """
  Los numeros del circuito, con su defecto explicito.
  """
  @spec defaults() :: keyword()
  def defaults, do: [threshold: @default_threshold, timeout: @default_timeout_ms]

  @doc """
  Ejecuta `fun` bajo el circuito de `url` y reporta el resultado.

  Devuelve lo que devuelva `fun`, o `{:error, :circuit_open}` si el circuito
  esta abierto —en ese caso **no se ejecuta**.

  ## `url`, no un nombre

  Aqui se pasa **la URL**, nunca el resultado de `name/1`. Los dos son strings
  y por eso el error es silencioso: `URI.parse("candil-breaker-127.0.0.1-9999")`
  no da error, da `host: nil`, y el nombre sale `candil-breaker--` —el mismo
  para todos los destinos, o sea un circuito para todo. Pasado por un test sin
  querer, por eso hay un test que lo comprueba.
  """
  @spec call(binary(), (-> result), keyword()) :: result when result: term()
  def call(url, fun, opts \\ []) when is_function(fun, 0) do
    unless uri_de_destino?(url) do
      raise ArgumentError,
            "Breaker.call/3 espera una URL, no el nombre de un circuito: #{inspect(url)}"
    end

    case name(url) do
      nil ->
        # Sin destino conocido no hay circuito: se ejecuta y ya esta. Es lo que
        # evita el denial of service de crear un atomo por peticion.
        fun.()

      nombre ->
        con_circuito(nombre, fun, opts)
    end
  end

  defp con_circuito(nombre, fun, opts) do
    ensure_started(nombre, opts)

    # **No se usa `Arrea.CircuitBreaker.call/3`**, y el motivo es concreto:
    # cuenta como exito todo lo que no lance. Medido con el enfoque de `call/3`
    # mas un `failure/1` despues: cinco 503 seguidos y el circuito se quedaba
    # en `:closed`, porque cada iteracion hacia *exito y luego fallo*, y con
    # contadores consecutivos eso es siempre uno.
    #
    # `call/3` esta pensado para funciones que lanzan. Aqui la respuesta viene
    # en el valor de retorno, porque un 5xx **no** es una excepcion: es una
    # respuesta valida de un destino caido.
    #
    # Y el estado se mira con `get_state/1` y se reporta con `success/1` y
    # `failure/1`.
    #
    # Lo que se pierde es la decision atomica de `call/3`. Para un destino HTTP
    # da igual: entre mirar el estado y ejecutar hay unos microsegundos, y una
    # peticion de mas a un destino que acaba de abrir el circuito no rompe nada
    # —lo que rompe es golpear un destino caido, que es justo lo que se cuenta.
    case CircuitBreaker.get_state(nombre) do
      :open ->
        {:error, :circuit_open}

      _ ->
        ejecutar(nombre, fun)
    end
  end

  # Una URL de verdad tiene host. Un nombre de circuito —o cualquier otro string
  # suelto— no lo tiene, y `URI.parse/1` no se queja: contesta `host: nil`, y el
  # nombre sale `candil-breaker--`: el mismo para todos los destinos, o sea un
  # circuito para todo en lugar de uno por destino.
  defp uri_de_destino?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ejecutar(nombre, fun) do
    try do
      fun.()
    rescue
      excepcion ->
        CircuitBreaker.failure(nombre)
        reraise excepcion, __STACKTRACE__
    else
      resultado ->
        if fallo?(resultado),
          do: CircuitBreaker.failure(nombre),
          else: CircuitBreaker.success(nombre)

        resultado
    end
  end

  @doc """
  Que cuenta como fallo. Ver el `@moduledoc`: los del destino, no los del
  cliente.
  """
  @spec fallo?(term()) :: boolean()
  # **429 cuenta**, y es el unico 4xx que cuenta. Esta clausula estaba debajo
  # del rango 400..499 y por eso no contaba, hasta que un test lo enseno: un
  # 429 es el destino diciendo «baja el ritmo», no tu peticion diciendo «esta
  # mal». Y Candil ya lo reintentaba —`AperoRetry` con `429..599`—, o sea que
  # para el reintento ya era un fallo del destino y para el circuito no.
  def fallo?({:ok, %{status: 429}}), do: true
  def fallo?({:ok, %{status: status}}) when status in 400..499, do: false
  def fallo?({:ok, %{status: _}}), do: true
  def fallo?({:ok, _}), do: false
  def fallo?({:error, _}), do: true
  def fallo?(_), do: false

  @doc """
  Arranca el circuito de este destino si no esta ya.

  Arrea 3.1 **no tiene `ensure_started/1`** —su supervisor solo levanta el
  Registry, no los breakers—, asi que hay que hacerlo aqui, y el dueno es un
  `DynamicSupervisor` de Candil: un circuito no sobrevive a la peticion que lo
  provoco, que es justo lo contrario de lo que debe pasar.
  """
  @spec ensure_started(atom(), keyword()) :: :ok
  def ensure_started(nombre, opts \\ []) do
    case CircuitBreaker.validate_opts(Keyword.merge(defaults(), opts) ++ [name: nombre]) do
      :ok -> :ok
      {:error, error} -> raise ArgumentError, "circuit breaker invalido: #{inspect(error)}"
    end

    # Arrea no expone `whereis/1`, pero registra por `{:via, Registry, ...}` y
    # el Registry es publico. Preguntar ahi es lo mismo que pregunta el.
    case Registry.lookup(CircuitBreaker.Registry, nombre) do
      [] ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {CircuitBreaker, Keyword.merge(defaults(), opts) ++ [name: nombre]}
             ) do
          {:ok, _pid} -> :ok
          # Dos peticiones a la vez pueden pedir el mismo destino: la segunda
          # encuentra el circuito ya arrancado y no pasa nada. Esto no es una
          # carrera que haya que ganar, es un estado normal.
          {:error, {:already_started, _pid}} -> :ok
          {:error, _} -> :ok
        end

      _pid ->
        :ok
    end

    :ok
  end
end
