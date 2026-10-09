defmodule Candil.Provider.Adapter do
  @moduledoc """
  El dialecto de cada proveedor, en un sitio y solo uno.

  ## Por qué existe

  Antes de esto el tipo de un provider vivia en DOS listas que tenian que
  coincidir y no podían:

  ```elixir
  # provider.ex
  @provider_types [:openai, :anthropic, :ollama, :openai_compatible, :azure_openai]

  # inference/chat.ex
  defp build_request_body(:anthropic, ...), do: ...
  defp build_request_body(:openai, ...), do: ...
  ```

  Añadir un tipo obligaba a editar los dos ficheros. Olvidar el primero daba
  «unknown type: X» al validar; olvidar el segundo daba un `FunctionClauseError`
  en mitad de una llamada, con el token ya gastado. **La misma verdad en dos
  sitios**, que es lo que produce los bugs.

  Aqui el registro es la unica fuente: `Provider.validate/1` pregunta al registro
  si el tipo existe, y `Inference` pregunta al registro cual es su adaptador.

  ## Como se usa

  Un tercero registra su provider y no toca Candil:

  ```elixir
  Candil.Provider.Adapter.register(:mi_endpoint, MiEndpoint)
  ```

  Y a partir de ahi `mi_endpoint` es un tipo valido, con su URL, su cuerpo, sus
  cabeceras y sus errores. **Ese test es el que decide si Candil es un framework
  o un programa con muchos modulos.**

  ## El payload es opaco

  Un adaptador recibe lo que tiene y devuelve lo que tiene. No sabe que hay un
  modelo, ni una VRAM, ni un Consumer. Solo conoce HTTP.
  """

  @type type :: atom()
  @type t :: module()

  # Lo que devuelve `Candil.HTTP`: una tupla con el codigo y el cuerpo ya
  # parseado. NO un mapa crudo. Poner `map()` aqui hacia que dialyzer marque
  # `callback_arg_type_mismatch` en los tres adaptadores, porque el callback
  # promete una cosa y todos los que lo implementan reciben otra.
  @type http_result :: {:ok, %{status: integer(), body: term()}} | {:error, term()}

  @doc "Construye el cuerpo de la peticion."
  @callback build_body(model :: String.t(), messages :: [map()], opts :: keyword()) :: map()

  @doc "La URL a la que se manda esa peticion."
  @callback chat_url(Candil.Provider.t()) :: String.t()

  @doc """
  Las cabeceras. Sin `api_key` no hay cabeceras, y eso es lo que hace que este
  provider sea de los que necesitan clave.
  """
  @callback auth_headers(Candil.Provider.t()) :: [{String.t(), String.t()}]

  @doc "Convierte una respuesta cruda en lo que Candil entiende."
  @callback parse_response(http_result(), Candil.Provider.t()) :: {:ok, term()} | {:error, term()}

  @doc "Los modelos que el provider ofrece, si los sabe."
  @callback models(Candil.Provider.t()) :: [String.t()]

  # NO hay un callback `requires_api_key?/0` aqui, y es a proposito.
  #
  # `:openai` y `:openai_compatible` COMPARTEN adaptador: los dos hablan el
  # mismo protocolo y solo cambia la URL. Si el adaptador dijera "necesito
  # clave", `openai_compatible` la pediria tambien, y ese tipo existe
  # precisamente para los endpoints que NO la piden (un vLLM en local, un LM
  # Studio). Por eso la pregunta la contesta el PROVIDER, no el adaptador.

  # ── la tabla ────────────────────────────────────────────────────────────────

  @table __MODULE__

  # La crea quien la use la primera vez, no solo el arranque: un test que
  # registre un provider sin levantar la aplicacion tiene que poder.
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  # Registra los providers que trae Candil, la PRIMERA vez que se consulta el
  # registro y si no estan ya.
  #
  # Que sea perezoso y no "al arrancar" importa: `validate/1` lo consulta
  # `Store.register/2`, y un host que use Candil como libreria no tiene por que
  # haber arrancado la aplicacion. Con el registro ligado al arranque, los
  # 99 tests que no levantan la app veian un registro vacio y todos los tipos
  # parecian "unknown".
  @spec ensure_builtin!() :: :ok
  def ensure_builtin! do
    ensure_table()

    if :ets.info(@table, :size) == 0 do
      Candil.Provider.Adapters.builtin!()
    end

    :ok
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  @spec start_link(keyword()) :: :ok
  def start_link(_opts \\ []) do
    ensure_table()
  end

  # ── el registro ──────────────────────────────────────────────────────────────

  @doc """
  Registra un adaptador para un tipo de provider.

  Devuelve `{:error, {:incomplete_adapter, …}}` si el módulo no implementa el
  behaviour entero: es preferible que falle aqui, al registrar, que en mitad de
  una llamada HTTP.
  """
  @spec register(type(), t()) :: :ok | {:error, term()}
  def register(type, module) when is_atom(type) and is_atom(module) do
    ensure_table()

    # `function_exported?/3` responde `false` para un modulo que no esta
    # CARGADO, no para uno al que le falte el callback. Sin esto, registrar un
    # adapter recien compilado dice "incompleto" aunque lo este, y el mensaje
    # miente sobre la causa.
    # NO se comprueba con `function_exported?/3`: responde `false` para un
    # modulo que no esta cargado, y durante el arranque —justo cuando se
    # registran los builtin— los modulos anidados todavia no lo estan. El
    # resultado era que los cinco de Candil se rechazaban a si mismos con
    # "incompleto", que es mentira: el problema era de carga, no de callbacks.
    #
    # Se comprueba contra el behaviour de verdad: si el modulo declara
    # `@behaviour`, Elixir garantiza que cumple. Y si no lo declara, el propio
    # `__info__(:attributes)` lo dice.
    missing =
      if behaviour_implemented?(module) do
        []
      else
        __MODULE__.behaviour_info(:callbacks)
      end

    if missing == [] do
      :ets.insert(@table, {type, module})
      :ok
    else
      {:error, {:incomplete_adapter, module, missing}}
    end
  end

  # Si el modulo declara implementar este behaviour.
  @spec behaviour_implemented?(module()) :: boolean()
  defp behaviour_implemented?(module) do
    _ = Code.ensure_loaded(module)

    # `__info__(:attributes)` devuelve `[{behaviour, [Modulo]}]`. Cada valor es
    # una lista de modulos, y `List.flatten/1` sobre un valor que no es lista
    # revienta con un FunctionClauseError que no dice nada de adaptadores.
    # El `|>` se traga el `for` entero, no la comparacion: sin parentesis esto
    # acaba siendo `Enum.any?(for ... , mod == __MODULE__)` y revienta con un
    # FunctionClauseError que no menciona los adaptadores ni los behaviours.
    Enum.any?(
      for {:behaviour, mods} <- module.__info__(:attributes),
          mod <- mods,
          do: mod == __MODULE__
    )
  end

  @doc "Si hay un adaptador registrado para ese tipo."
  @spec registered?(type()) :: boolean()
  def registered?(type) do
    ensure_builtin!()
    :ets.member(@table, type)
  end

  @doc "El adaptador de un tipo, o `:error` si no hay."
  @spec adapter_for(type()) :: {:ok, t()} | :error
  def adapter_for(type) do
    ensure_builtin!()

    case :ets.lookup(@table, type) do
      [{^type, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc "La lista de tipos registrados."
  @spec types() :: [type()]
  def types do
    ensure_table()

    @table
    |> :ets.match({:"$1", :_})
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  Vacía el registro. Solo para tests.

  ## Por qué el `if` y no un `|>`

  `:ets.delete_all_objects/1` devuelve `true`, no `:ok`. Un `@spec reset() :: :ok`
  con esa llamada detras es un contrato roto que dialyzer marca como
  `invalid_contract`, y con razon: el modulo dice una cosa y hace otra.

  Aqui se dice lo que se quiere decir —`:ok`— en vez de propagar el `true` de la
  tabla, que no le importa a nadie.
  """
  @spec reset() :: :ok
  def reset do
    ensure_table()
    _ = :ets.delete_all_objects(@table)
    :ok
  end
end
