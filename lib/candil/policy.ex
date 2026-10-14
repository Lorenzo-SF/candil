defmodule Candil.Policy do
  @moduledoc """
  Quién va primero en un destino: la política de turnos.

  El orden de este módulo y el de §3 del diseño
  (`docs/06-capacidad-y-politica/README.md`): el enrutado elige **qué** modelo
  sirve una petición, y esto decide **en qué orden** atiende el destino. Son dos
  ejes y no se mezclan. `one_for_all` no dice a qué modelo vas; dice quién entra
  primero cuando todos quieren el mismo.

  ## Los tres modos, y por qué solo hay dos

  | Modo | Qué garantiza |
  |---|---|
  | `:one_for_one` | el destino **no es exclusivo**: el que entra no molesta a nadie y no hay turno |
  | `:rest_for_one` | el destino es exclusivo: el que entra sale, y el primero pasa; si el titular **cede** el turno, vuelve al final de la cola |
  | `:one_for_all` | el destino es exclusivo: el que entra sale, y el primero pasa; si el titular **cede** el turno, lo pierde |

  Y aquí está lo que el diseño prometía tres y son dos, dicho antes de
  escribir el código y no después:

      una cola con A, B, C esperando, cada peticion de una vez

      one_for_all  :  A entra -> sale -> B entra -> sale -> C entra.   FIN
      rest_for_one :  A entra -> sale -> B entra -> sale -> C entra.   FIN
                                       ↑
                    A volvió AL FINAL, pero ya no hay a quien darle turno

  Para peticiones de una vez **los dos modos hacen exactamente lo mismo**, y hay
  un test que lo demuestra en vez de una frase que lo afirme
  (`"los dos modos seriales coinciden si nadie cede el turno"`). Se diferencian
  en un solo caso: cuando quien tiene el turno **cede antes de terminar**
  (`yield/1`).

  ## Por qué no hay un quantum, y por qué no se inventa

  Porque en un backend de inferencia **no se puede cortar una inferencia a
  medias**: la mitad del trabajo está hecho y tirarla es perderla. Un modo que
  solo se diferenciara del otro por un quantum sería un modo que nadie podría
  activar sin mentir sobre lo que pasa, y tres nombres que prometen tres cosas
  y dos son la misma es peor que dos modos y un test que diga cuándo coinciden.

  El que cede el turno es **quien dice que cede** (`yield/1`), nunca la cola por
  su cuenta. Un consumidor de larga vida —algo que va a pedir turno muchas
  veces— es lo que hace valer la diferencia, y no existe todavía en Candil.

  ## El camino caliente no pasa por aqui

  El defecto es `:one_for_one` y en ese modo **no hay cola**: no se arranca un
  proceso, no se hace un `GenServer.call`, no se emite un evento. El usuario que
  llama a una API —y el que llama a un modelo local con la GPU libre— nunca ve
  una cola, y eso no es una promesa del `@moduledoc` sino un test
  (`"el camino caliente no toca la cola"`) que mira el proceso, los eventos y el
  `self()` de dentro de la función.

  ## Las tres reglas que el valor no puede cambiar

  1. **Ninguna devuelve un destino vetado.** La elegibilidad no la decide esta
     capa: la decide quien llama, y se le pasa en `:admit`. Si `:admit`
     contesta un error, la petición **no se encola** y el error sale tal cual,
     en los tres modos. Un rechazo de recursos que devuelve algo que no debe
     recibirlo es un fallo de seguridad, no una política.
  2. **Nunca miente con números.** Esta capa no fabrica motivos ni cifras: no
     dice «no cabe», no dice `:busy`, no inventa un `0`. O propaga el error que
     le dieron (números incluidos) o no dice nada y **espera**. Un `-1` que
     significa «no lo sé» y un `0` que significa «no hay» son el mismo bug, y
     por eso aquí no hay ningún número.
  3. **Un destino que no existe no se encola.** Y contesta el error que ya
     existe —`Candil.Error.model_not_found/1`, el mismo que devuelve
     `Candil.Inference.chat_local/3`— en vez de un cuarto motivo que solo
     existiría aquí.

  ## La configuración

  En `[general.policy]` del fichero, y en el app env para lo que un test
  necesita fijar sin escribir un fichero:

      [general.policy]
      default = "one_for_one"

      [general.policy.coder]
      mode = "one_for_all"

  El defecto es **el aburrido**: `one_for_one`, que es no hacer nada.

  ## Por qué no se persiste nada

  Porque un turno en curso no sobrevive al proceso que lo pidió, y un fichero
  que sobrevive a ese proceso es una lista de peticiones muertas. El estado vive
  en el proceso del destino y **está hecho** para perderse. `instances.json` es
  de Candil y es del runtime, no de la política.

  ## Lo que esta capa no sabe

  Que es un destino. No sabe qué es una GPU, ni un proveedor, ni un puerto, ni
  lo que cuesta. La capacidad —«¿cabe? y en qué unidades»— la trae
  `Arrea.Resource`, que es la misma forma para megas y para euros.
  """

  alias Candil.Error
  alias Candil.Policy.{Destination, Turn}
  alias Candil.Store

  @typedoc "Los tres modos, y solo tres."
  @type mode :: Turn.mode()

  @typedoc "Lo que se puede poner delante: el `alias` de un modelo, un engine o un provider."
  @type destination :: Turn.destination()

  @typedoc "Lo que devuelve `run/3`."
  @type run_result(result) :: {:ok, result} | {:error, term()}

  @doc """
  Para todas las colas vivas.

  Es lo que hace la suite entre tests, y **no es un atajo de test**: una cola
  de un destino que el siguiente test ha vuelto a registrar como no exclusivo
  es un proceso vivo al que el camino caliente llega, y el camino caliente
  tiene que poder prometer que no llega a ninguna parte.
  """
  @spec stop_all() :: :ok
  def stop_all do
    # `Destination` se registra en `Candil.Registry` con la clave
    # `{:policy_destination, destino}`, no en una tabla propia. Preguntar donde
    # no esta el registro es como se cae una cola: se para la mitad.
    Candil.Registry
    |> Registry.select([{{{:policy_destination, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.each(&Destination.stop/1)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Si este destino es **exclusivo**: si lo tiene uno, no caben dos.

  La respuesta sale del **modelo**, no de un interruptor global, y esa es toda
  la diferencia. Con un interruptor global, quien tiene tres APIs y una GPU
  tiene que elegir un modo para los cuatro, y cualquier eleccion es mala para
  tres de ellos. Con una propiedad por destino, **las APIs no pasan por la cola
  y la GPU si, sin que nadie haya configurado nada.**

  Y el defecto es `false`: sin cola. El camino caliente —un destino libre, que es
  el caso normal— **no toca esta capa**, y eso no es una promesa del
  `@moduledoc`: hay un test que mide que no se arranca ni un proceso.

  ## Lo que no hay aqui

  No hay modo, ni enum de modos, ni `rest_for_one`. Ese ultimo no se implementa
  porque **no tiene caso**: solo tendria sentido cuando existiera un destino que
  pueda soltar el turno antes de terminar. Ver `yield/1`.
  """
  @spec exclusive?(destination()) :: boolean()
  def exclusive?(destination) when is_atom(destination) or is_binary(destination) do
    case lookup(destination) do
      {:ok, model} -> model.exclusive == true
      :error -> false
    end
  end

  def exclusive?(_destination), do: false

  @doc """
  Toma el turno de un destino, y devuelve el recibo.

  Bloquea mientras haya cola; en `:one_for_one` no bloquea nunca.

  ## Opciones

    - `:admit` — funcion de aridad 0 que contesta `:ok` o `{:error, motivo}`.
      Es la eligibilidad, y es de quien llama: esta capa no sabe que es un
      destino vetado ni lo que se le pide. Si contesta cualquier otra cosa, se
      rechaza la peticion en vez de admitirla: un admit que no se entiende es un
      admit que no se puede defender.

  ## Cuando se rompe

    - `{:error, %Candil.Error{reason: :model_not_found}}` — el destino no
      existe. No se encola.
    - `{:error, {:error, motivo}}` del `:admit` — lo que dijo, sin tocarlo.
    - `{:error, :unknown_mode}` — el modo configurado no es uno de los tres.
    - `{:error, :mode_conflict}` — el destino ya tiene cola con otro modo serial.
    - `{:error, :policy_unavailable}` — la cola del destino se murio mientras
      esperaba. Nadie se queda esperando a un proceso que no esta.
  """
  @spec enter(destination(), keyword()) :: {:ok, Turn.t()} | {:error, term()}
  def enter(destination, opts \\ []) do
    with :ok <- eligible(destination, opts) do
      # Exclusivo -> cola de uno en uno. No exclusivo -> ni se mira: no hay
      # nada que ordenar porque no hay competencia.
      if exclusive?(destination) do
        enter_serial(destination, :one_for_all)
      else
        # Y si DEJARA de serlo, su cola se para. La vida de la cola sigue a la
        # propiedad, y no laRemember al ultimo `enter/2` que la arranco: un
        # destino que ya no es exclusivo no puede quedarse con un proceso
        # vivo al que el camino caliente deberia no llegar.
        Destination.stop(destination)
        {:ok, %Turn{destination: destination, mode: :one_for_one}}
      end
    end
  end

  @doc """
  Ejecuta `fun` con el turno, y lo suelta al terminar.

  `fun` corre en **este** proceso. Por eso la unidad de la cola puede ser la
  peticion y no un trabajo en segundo plano: lo que corre es lo que el usuario
  pidio, y termina cuando termina.

  El turno se suelta en un `after`, asi que una excepcion, un `throw` o un
  `exit` **no dejan el destino bloqueado** con una peticion que ya no existe.

  ## Por qué se puede volver a llamar sin encolar dos veces

  Porque la cola se toma **en el punto que habla con el destino** —ver
  `Candil.Inference`— y no en un camino de entrada. Eso significa que un camino
  que ya tiene el turno llama a otro que tambien lo toma, y sin esto el segundo
  `enter/2` seria el mismo proceso pidiendo otra vez una cola que ya tiene: en
  un destino **exclusivo** se quedaria esperando a si mismo.

  Asi que `run/3` **es idempotente por proceso y destino**: si este proceso ya
  tiene el turno de este destino, ejecuta y no se encola. Quien envuelve a
  quien no tiene que saber nada de esto, y el error que se evita —esperarse a
  uno mismo— no es un caso raro: es lo que hace cualquiera que envuelva la
  llamada dos veces.
  """
  @spec run(destination(), (-> result), keyword()) :: run_result(result) when result: term()
  def run(destination, fun, opts \\ []) when is_function(fun, 0) do
    if Process.get({__MODULE__, destination}) do
      # El turno ya es de este proceso: no hay nada que pedir.
      {:ok, fun.()}
    else
      case enter(destination, opts) do
        {:ok, turn} ->
          Process.put({__MODULE__, destination}, true)

          try do
            {:ok, fun.()}
          after
            Process.delete({__MODULE__, destination})
            finish(turn)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Termina el turno. En `:one_for_one` no toca ningun proceso.
  """
  @spec finish(Turn.t()) :: :ok | {:error, term()}
  def finish(%Turn{token: nil}), do: :ok

  def finish(%Turn{destination: destination, token: token}),
    do: Destination.finish(destination, token)

  @doc """
  Cede el turno sin terminar la peticion.

  Es lo **unico** que separa `:rest_for_one` de `:one_for_all`, y por eso es lo
  unico que el modulo no resuelve por su cuenta: el que cede el turno sabe lo
  que esta haciendo, y aqui no hay forma de saberlo.

    - `:rest_for_one` — vuelve al final de la cola. `{:ok, turno}` con un turno
      **nuevo**, y esta llamada **no vuelve** hasta que le toque otra vez.
    - `:one_for_all` — lo pierde. `{:error, :discarded}`, y el `finish/1` de
      ese turno ya no vale.
    - `:one_for_one` — `{:error, :not_queued}`: no hay turno que ceder.
  """
  @spec yield(Turn.t()) :: {:ok, Turn.t()} | {:error, term()}
  def yield(%Turn{mode: :one_for_one}), do: {:error, :not_queued}

  def yield(%Turn{destination: destination, token: token, mode: mode}) do
    case Destination.yield(destination, token) do
      {:ok, turn, new_token} ->
        {:ok, %Turn{destination: destination, mode: mode, turn: turn, token: new_token}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Que esta pasando en un destino, o `nil` si no hay cola para el.

  `nil` es una respuesta, no una falta: en `:one_for_one` **no hay cola**, y
  por eso el camino caliente no la crea nunca.
  """
  @spec status(destination()) :: Destination.status() | nil
  def status(destination), do: Destination.status(destination)

  # ── Internos ─────────────────────────────────────────────────────────────────

  defp enter_serial(destination, mode) do
    case Destination.enter(destination, mode) do
      {:ok, turn, token} ->
        {:ok, %Turn{destination: destination, mode: mode, turn: turn, token: token}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Primero la elegibilidad, y antes de mirar la exclusividad: que el destino
  # exista y que este permitido **no dependen de como se reparte el turno**, que
  # es exactamente por lo que ningun camino puede devolver algo vetado.
  defp eligible(destination, opts) do
    if registered?(destination) do
      admit(Keyword.get(opts, :admit))
    else
      {:error, Error.model_not_found(destination)}
    end
  end

  defp admit(nil), do: :ok
  defp admit(fun) when is_function(fun, 0), do: check_admission(fun.())
  defp admit(other), do: {:error, {:invalid_admission, other}}

  defp check_admission(:ok), do: :ok
  defp check_admission({:error, reason}), do: {:error, reason}
  defp check_admission(other), do: {:error, {:invalid_admission, other}}

  defp registered?(destination) when is_atom(destination), do: Store.registered?(destination)

  # El destino puede venir como string. `to_existing_atom/1` y no `to_atom`: un
  # alias que no existe tiene que ser un fallo ruidoso, no un atomo nuevo
  # creado a partir de una cadena.
  defp lookup(destination) when is_binary(destination) do
    String.to_existing_atom(destination) |> lookup()
  rescue
    ArgumentError -> :error
  end

  defp lookup(destination) when is_atom(destination) do
    case Store.get_model(destination) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> :error
    end
  end
end
