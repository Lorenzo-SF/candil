defmodule Candil.Agents.Breaker do
  @moduledoc """
  El tercer cerrojo del §8.3: un agente que se cuelga se cierra solo.

  Las otras dos defensas del cuelgue ya estaban (F5.3): la vuelta va en una
  `Task` con plazo —pasado, se mata y quien llama recibe
  `{:error, :timeout, []}`— y el agente sigue vivo. Lo que faltaba es este:
  **cinco cuelgues seguidos y deja de intentarlo**. Sin el, un llamante que
  reintenta contra un backend colgado paga el plazo entero cada vez para
  recibir siempre lo mismo, que es la forma mas cara de no enterarse.

  ## Que cuenta como fallo

  **Solo el plazo agotado.** Cualquier otra cosa —una respuesta, o un error
  del motor— es «contesto, aunque contestara que no», y eso cierra el
  circuito. La linea es la del propio §8.3: un cuelgue no es un error, es una
  **ausencia** de error, y lo que este cerrojo vigila es la ausencia.

  ## Donde vive el estado, y por que no en `Arrea.CircuitBreaker`

  En el **proceso del agente**. El circuito de HTTP es un registro por destino
  porque lo llaman muchos procesos; el de un agente tiene **un solo escritor y
  un solo lector —el mismo**, y un registro compartido ahi seria coordinar lo
  que no se coordina. De propina: un `GenServer` ya serializa sus llamadas, y
  no hay dos comprobaciones a la vez que puedan pasar las dos, que es el unico
  problema que un circuito normalmente tiene que resolver.

  Y una consecuencia que se dice en vez de esconderse: **el estado muere con
  el proceso**. Para el cuelgue da igual —un cuelgue no tira al agente—, pero
  un agente que **revienta** en bucle vuelve con el contador a cero. Esa mitad
  del §8.3 no la cubre este modulo: un reinicio es del supervisor (intensidad
  10 en 5 s) y un circuito que sobreviva a los reinicios necesita decidir
  **quien** lo consulta antes de arrancar, que es diseno de supervisor. Queda
  escrito alli con lo que haria falta.

  ## Los numeros

  `5` cuelgues seguidos abren, y `30 000` ms de enfriamiento antes de dejar
  pasar una sonda. Son **los mismos del breaker de HTTP**
  (`Candil.HTTP.Breaker`), que a su vez tomo los 30 s del plazo de
  `Arrea.Command`: no hay motivo para tener dos relojes distintos en el mismo
  producto. Se configuran al arrancar el agente con `:breaker_threshold` y
  `:breaker_cooldown_ms`.

  ## El ciclo

  | Estado | La puerta | Vuelve a |
  |---|---|---|
  | `:closed` | corre | — |
  | `:open` | contesta `{:error, {:agent_circuit_open, quien}, []}` **sin correr** | `:probe`, pasado el enfriamiento |
  | `:probe` | corre: una sonda | `:closed` si contesta; `:open` —con el enfriamiento reaplazado— si vuelve a colgarse |

  `now` entra como parametro en `check/2` y `record/3` en vez de leerse aqui:
  asi el modulo es una funcion pura del tiempo y sus tests no duermen.
  """

  @default_threshold 5
  @default_cooldown_ms 30_000

  @type estado :: :closed | :open | :probe
  @type t :: %__MODULE__{
          failures: non_neg_integer(),
          opened_at: integer() | nil,
          threshold: pos_integer(),
          cooldown_ms: pos_integer()
        }

  defstruct failures: 0,
            opened_at: nil,
            threshold: @default_threshold,
            cooldown_ms: @default_cooldown_ms

  @doc """
  Los numeros, con su defecto explicito — como en `Candil.HTTP.Breaker`.
  """
  @spec defaults() :: keyword()
  def defaults, do: [threshold: @default_threshold, cooldown_ms: @default_cooldown_ms]

  @doc """
  Un circuito cerrado, con los numeros de `opts`.

  `opts` es lo que le llega al agente: se leen `:breaker_threshold` y
  `:breaker_cooldown_ms`, y las claves que no son suyas se ignoran.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defectos = defaults()

    %__MODULE__{
      threshold: Keyword.get(opts, :breaker_threshold, defectos[:threshold]),
      cooldown_ms: Keyword.get(opts, :breaker_cooldown_ms, defectos[:cooldown_ms])
    }
  end

  @doc """
  El estado del circuito **ahora**, sin tocarlo.
  """
  @spec check(t(), integer()) :: estado()
  def check(%__MODULE__{opened_at: nil}, _now), do: :closed

  def check(%__MODULE__{opened_at: at, cooldown_ms: cooldown}, now) do
    if now - at >= cooldown, do: :probe, else: :open
  end

  @doc """
  Cuenta el resultado de una vuelta.

  `:answered` («cualquier cosa que no sea el plazo», ver `verdict/1`) resetea.
  Un `:timeout` suma, y abre al llegar al umbral — **o reaplaza el
  enfriamiento si ya estaba abierto**: una sonda que vuelve a colgarse es un
  fallo nuevo, y sin reaplazarlo la sonda siguiente lo encontraria medio
  abierto para cualquiera que llegue.
  """
  @spec record(t(), :timeout | :answered, integer()) :: t()
  def record(%__MODULE__{} = breaker, :answered, _now) do
    %{breaker | failures: 0, opened_at: nil}
  end

  def record(%__MODULE__{} = breaker, :timeout, now) do
    failures = breaker.failures + 1

    if breaker.opened_at != nil or failures >= breaker.threshold do
      %{breaker | failures: failures, opened_at: now}
    else
      %{breaker | failures: failures}
    end
  end

  @doc """
  El veredicto de una vuelta, desde su resultado.

  Solo el plazo es fallo (ver el `@moduledoc`): un `{:error, :no_backend, _}`
  o un `{:error, {:model_not_up, _}, _}` son el motor **contestando** que no.
  """
  @spec verdict(term()) :: :timeout | :answered
  def verdict({:error, :timeout, _trace}), do: :timeout
  def verdict(_otra), do: :answered
end
