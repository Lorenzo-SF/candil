defmodule Candil.CLI.Serve do
  @moduledoc """
  `candil serve` — el gateway, desde el terminal.

  Es la mitad que le faltaba a la fase 8. Los modulos del gateway, los diez
  handlers y los tests de punta a punta ya estaban; lo que no existia era la
  forma de levantar todo eso **sin escribir Elixir**. `Gateway.start/1` ya
  arrancaba Bandit y devolvia el puerto real; este comando era su unico llamador
  de produccion que faltaba.

  ## Los ajustes son flags, y todavia no hay seccion `[gateway]`

  El schema del TOML tiene cinco secciones —`general`, `engine`, `model`,
  `provider`, `consumer`— y ninguna es el gateway. Anadir una es tocar el
  schema, el hydrate y la plantilla para ganar lo que un flag ya da; el dia que
  un ajuste tenga que sobrevivir a un reinicio sin escribirlo en la linea de
  comandos, la seccion se anade y el flag manda. Hasta entonces, una sola
  verdad: lo que se declara en `Candil.CLI`.

  ## Las claves salen del entorno

  `--auth api_key` exige clave, y las claves **no** van en el TOML:
  `Candil.Gateway.Auth` ya lo dice — una clave en un fichero acaba en el
  historial de la shell, en `ps` y en cada copia del directorio.
  `CANDIL_API_KEYS` (separadas por comas) es el camino normal; `--api-key`,
  que se puede repetir, es para una prueba de una tarde y **manda** sobre el
  entorno.

  ## El banner dice el puerto de verdad

  Con `--port 0` el puerto lo elige el sistema. El banner imprime el que
  `Gateway.start/1` devuelve —el que de verdad se ha cogido— y no el cero
  pedido: un listener del que no se sabe el puerto no sirve para lo unico que
  se le pide, que es conectarse. Es el mismo defecto que tenia `candil run`,
  que anunciaba un engine que no habia arrancado.

  ## Se queda en primer plano, y si el listener se cae, lo dice

  No hay `--detach`: un gateway en segundo plano que no contesta no tiene a
  quien contarselo. El proceso espera el `EXIT` del listener y, si llega con un
  motivo, lo imprime y el escript sale con 1 en vez de morir en silencio.
  """

  alias Alaja.Components.{Header, Table}
  alias Alaja.Printer, as: Say
  alias Candil.Gateway

  @default_host "127.0.0.1"
  @default_port 7777

  # El nombre de la variable esta en un solo sitio porque es el contrato que
  # hay que contarle a quien despliega: `Gateway.Auth` dice que las claves
  # vienen del entorno y no del TOML; esto le pone nombre.
  @api_keys_env "CANDIL_API_KEYS"

  # Un host que no es loopback con `auth = none` deja el catalogo entero —GPU
  # incluida— al primero que llegue al puerto. No se prohibe: puede haber un
  # proxy delante y una red de confianza detras. Se **dice**, que es lo
  # contrario de dejarlo pasar en silencio.
  @loopback ~w(127.0.0.1 localhost ::1)

  @doc """
  Arranca el gateway, lo anuncia y se queda. Devuelve el estado de salida.
  """
  @spec run(map() | keyword()) :: :ok | :error
  def run(opts) do
    # Antes de arrancar: `Bandit.start_link/1` enlaza el listener con este
    # proceso y, sin trapar las salidas, una caida del listener se lleva por
    # delante al que iba a contarla.
    Process.flag(:trap_exit, true)

    case start(opts) do
      {:ok, %{pid: pid}} -> await(pid)
      :error -> :error
    end
  end

  @doc """
  Arranca el gateway, imprime el banner y devuelve sus datos.

  Separado de `run/1` para que se pueda probar sin quedarse dentro: `run/1` es
  `start/1` mas la espera, y todo lo que puede salir mal —una auth sin claves,
  un modo que no existe, un puerto ocupado— sale mal aqui, que es donde un test
  lo puede ver.
  """
  @spec start(map() | keyword()) :: {:ok, map()} | :error
  def start(opts) do
    case auth_mode(opts) do
      {:error, reason} ->
        Say.print_error(reason)
        :error

      {:ok, mode} ->
        flag_keys = List.wrap(get(opts, :api_key))
        keys = if flag_keys == [], do: env_keys(), else: flag_keys

        warn_ignored_keys(flag_keys, mode)

        host = get(opts, :host) || @default_host
        port = get(opts, :port) || @default_port

        case Gateway.start(host: host, port: port, auth: mode, api_keys: keys) do
          {:ok, info} ->
            banner(info, mode)
            warn_exposed(info, mode)
            Say.print("Los modelos se arrancan con `candil run <alias>`. Ctrl-C para parar.")
            {:ok, info}

          {:error, reason} ->
            Say.print_error(reason)
            :error
        end
    end
  end

  # La espera: el `EXIT` del listener. `:normal` no es una caida —es alguien
  # parando el servidor— y no hay nada que decir; cualquier otro motivo se
  # imprime, porque un gateway que deja de servir y no lo cuenta convierte un
  # fallo en un misterio.
  defp await(pid) do
    receive do
      {:EXIT, ^pid, :normal} ->
        :ok

      {:EXIT, ^pid, reason} ->
        Say.print_error("el gateway se ha caido: #{inspect(reason)}")
        :error
    end
  end

  defp banner(info, mode) do
    Header.print("candil serve",
      subtitle: "la API de OpenAI delante de tu catalogo",
      size: :medium
    )

    Table.print(
      rows: [
        ["escuchando", "http://#{info.host}:#{info.port}/v1"],
        ["auth", auth_line(mode)],
        ["consumidores", "cada cliente con su prefijo: /c/<nombre>/v1/..."],
        ["modelo", "\"auto\" lo elige el router; un nombre registrado va directo"]
      ],
      table_border: :rounded,
      padding: 1
    )

    :ok
  end

  defp auth_line(:none), do: "ninguna"
  defp auth_line(:api_key), do: "api key — Bearer obligatorio en cada peticion"

  # El atomo que habla `Gateway.Auth` y la palabra que acepta el flag no son lo
  # mismo, y traducir es de quien declara el flag: el gateway no tiene por que
  # saber como se escribe un flag. Un valor que no este en la tabla no llega al
  # gateway, que es lo que se quiere — un `--auth oauth` no arranca nada.
  @auth_modes %{"none" => :none, "api_key" => :api_key}

  @spec auth_mode(map() | keyword()) :: {:ok, Gateway.auth_mode()} | {:error, String.t()}
  defp auth_mode(opts) do
    case get(opts, :auth) do
      nil ->
        {:ok, :none}

      # La biblioteca —un host que embebe Candil, o un test— puede pasar ya el
      # atomo, que es lo que habla `Gateway.Auth`.
      mode when mode in [:none, :api_key] ->
        {:ok, mode}

      mode when is_binary(mode) ->
        translate_auth(mode)

      other ->
        {:error, auth_error(other)}
    end
  end

  defp translate_auth(mode) do
    case @auth_modes do
      %{^mode => atom} -> {:ok, atom}
      _ -> {:error, auth_error(mode)}
    end
  end

  defp auth_error(value), do: "auth must be \"none\" or \"api_key\", got: #{inspect(value)}"

  # Claves del flag primero: son las que alguien ha escrito ahora mismo y ha
  # visto escribirlas. Las del entorno son ambiente —estan puestas para todos
  # los procesos de la sesion— y no son una senal de que este comando las
  # quiera: por eso no se avisa por ellas.
  defp env_keys do
    case System.get_env(@api_keys_env) do
      nil ->
        []

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp warn_ignored_keys([], _mode), do: :ok
  defp warn_ignored_keys(_keys, :api_key), do: :ok

  defp warn_ignored_keys(_keys, :none) do
    Say.print_warning("--api-key se ignora con auth = none; para exigirla, --auth api_key")
  end

  defp warn_exposed(info, :none) do
    if info.host in @loopback do
      :ok
    else
      Say.print_warning(
        "sin auth y escuchando en #{info.host}: cualquiera que llegue a ese puerto usa tus modelos"
      )
    end
  end

  defp warn_exposed(_info, :api_key), do: :ok

  defp get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
end
