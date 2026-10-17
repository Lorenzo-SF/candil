defmodule Candil.Refusal do
  @moduledoc """
  Qué pasa cuando **nadie puede** contestar la pregunta.

  Hasta ahora el enrutado tenia dos salidas y ninguna era una politica: o
  habia un candidato, o devolvia `:no_models_for_consumer` y se acababa. No
  habia forma de decir «espera, que ahora mismo no pero en un rato si», ni de
  contestarle al cliente **cuando** volver a probar.

  ## Las tres estrategias

  | | Que hace quien pregunta |
  |---|---|
  | **`:fail`** | error de capacidad, inmediato |
  | **`:wait`** | espera a que quepa, hasta un tope, y vuelve a preguntar |
  | **`:degrade`** | se sirve con otro modelo que si cubre, y se dice cual |

  Los numeros salen de la ronda del consultor, con la medicion que los
  respalda: una inferencia corta son **7 s**, una larga **13-30 s**, y con los
  turnos puestos la segunda peticion de un destino exclusivo espero **15 s** de
  mediana.

  ## El defecto es `:fail`, y no `:wait`, porque esta medido

  El consultor propuso `wait` por defecto. **Medido el 2026-10-14, es la peor
  de las dos**: con un solo caso de «no hay modelos» en la suite del router, la
  suite tardaba **60,3 s** con `wait` y **0,3 s** con `fail`. Doscientas veces.

  Y el motivo es que **`wait` no arregla nada en el caso de refusal**: si no hay
  ningun modelo que conteste, esperar 60 s no lo hace aparecer. `wait` tiene
  sentido cuando lo que falta es una **GPU ocupada**, que se libera sola; no
  cuando lo que falta es un modelo que no esta, que no se libera nunca.
  Convertir un error de configuracion en un cuelgue de un minuto es taparlo.

  `wait` sigue disponible y es lo que hay que poner **a proposito**, por
  destino, para el caso que si lo justifica. Un defecto que casi nadie cambia
  es un contrato, y este no lo queremos como contrato.

  - **`wait_timeout_ms`: 60 000** — dos veces el peor caso medido (28 s). Por
    debajo de 30 s cortas peticiones que iban a resolverse; por encima de 120 s
    nadie espera sin saber por que.
  - **`global_wait_timeout_ms`: `nil`** — el tope global es un override para
    operadores que quieren un limite duro, no la politica base.
  - **`retry_after_ms`**: el **menor** de `30 000` y la mitad del timeout que se
    esta aplicando. El invariante es que `Retry-After <= wait_timeout`: un
    cliente que respeta el `Retry-After` no deberia encontrarse esperando el
    wait entero otra vez.

  ## `:degrade` NO esta aqui, y por que

  Degradar es **servir con otro modelo que cubra lo mismo y puntupe peor**, y
  para saber si otro modelo cubre lo mismo hay que saber **que pide la
  pregunta**. Sin el enrutado por cobertura, `degrade` seria adivinar: poner a
  un modelo que no razona a contestar una pregunta de razonamiento **no es
  degradar, es mentir**.

  Asi que aqui solo estan `:fail` y `:wait`, que no necesitan saber nada de la
  pregunta. Cuando exista la capacidad requerida, `degrade` se anade aqui y se
  comprueba en el sitio: **si la peticion pide `:reasoning` y no hay nadie con
  `:reasoning` que quepa, no se degrada, se falla.**

  ## El `typical_latency_s` del toml

  Un 60 s fijo es una apuesta: corta un modelo lento de CPU que tardaria 120 s,
  y hace esperar de mas a uno rapido. Por eso un destino puede declarar
  cuanto se demora en la realidad:

      [model.analyst]
      typical_latency_s = 120

  y entonces su wait es `2 × typical_latency_s` si esta declarado, y 60 s si no.
  Asi un destino lento tiene un wait lento **y solo suyo**, y uno rapido no
  espera por culpa de otro.

  Esto **funcionaba antes de estar cableado**: la funcion de abajo leia la
  clave, pero `Candil.Model` no la tenia en su `defstruct` y el esquema del
  toml acepta claves desconocidas sin decir nada. O sea que escribir esto en el
  catalogo no hacia nada y no fallaba. Medido el 2026-10-15; el campo existe
  ahora en `Candil.Model` y lo lee `Candil.Config.Hydrate`.

  Un valor que no sea un entero de segundos mayor que 0 se **rechaza al cargar**
  el catalogo, en vez de ignorarse.

  ## Lo que NO decide este modulo

  **No decide si algo cabe.** Eso lo mide `Arrea.Resource` y lo trae
  `Candil.Policy`. Aqui solo se decide **que hacer con lo que ya se sabe que
  no cabe**, que es una decision de politica y por eso tiene numeros.
  """

  alias Candil.Error

  @default_strategy :fail
  @default_wait_timeout_ms 60_000
  @default_retry_after_ms 30_000

  @refusal_errors [:no_models_for_consumer, :all_candidates_vetoed, :insufficient_capacity]

  @type strategy :: :fail | :wait | :degrade
  @type reason :: atom()

  @doc """
  Los numeros por defecto, con su origen. Un solo sitio donde se pueden ver.
  """
  @spec defaults() :: keyword()
  def defaults,
    do: [
      strategy: @default_strategy,
      wait_timeout_ms: @default_wait_timeout_ms,
      global_wait_timeout_ms: nil,
      retry_after_ms: @default_retry_after_ms
    ]

  @doc """
  Que errores de `route/2` son «no hay quien conteste» y no un fallo.

  Cualquier otro error pasa de largo: un `model_not_found` no se arregla
  esperando, y tratarlo como refusal seria esconder un error de configuracion
  detras de un 503.
  """
  @spec refusal_error?(term()) :: boolean()
  def refusal_error?(error), do: error in @refusal_errors

  @doc """
  El tope de espera de un destino, en milisegundos.

  `typical_latency_s` declarado **gana** a la constante, porque es una
  medicion de ese destino y 60 s es una de otro.
  """
  @spec wait_timeout_ms(map() | nil, keyword()) :: non_neg_integer()
  def wait_timeout_ms(modelo, config \\ []) do
    declarados = Keyword.get(config, :wait_timeout_ms, @default_wait_timeout_ms)

    case typical_latency_ms(modelo) do
      nil -> declarados
      tipico -> max(tipico * 2, declarados)
    end
  end

  @doc """
  El `Retry-After` de este refusal, en milisegundos.

  El **menor** de `30 000` y la mitad del tope aplicado. Un cliente que
  cumple lo que le dicen no vuelve a caer en el mismo timeout entero.
  """
  @spec retry_after_ms(non_neg_integer(), keyword()) :: non_neg_integer()
  def retry_after_ms(timeout_ms, config \\ []) do
    declarados = Keyword.get(config, :retry_after_ms, @default_retry_after_ms)
    min(declarados, div(timeout_ms, 2))
  end

  @doc """
  El error de capacidad que ve el cliente, con el `retry_after` dentro.

  El numero va en el contexto del error y **no** en la respuesta de Candil,
  para que un cliente HTTP pueda ponerlo en la cabecera sin tener que saber de
  donde salio. Ver `Candil.Error.no_capacity/2`.
  """
  @spec error(reason(), non_neg_integer()) :: Error.t()
  def error(reason, retry_after_ms), do: Error.no_capacity(reason, retry_after_ms)

  @doc """
  Aplica la politica cuando `intento` no encuentra a nadie.

  `intento` se vuelve a llamar mientras quede tiempo: con `:wait` se reintenta
  hasta agotar el tope **de este destino**, y con `:fail` no se reintenta ni
  una vez. El bucle es de Candil y no del cliente, y por eso el `wait` es por
  destino: esperar a que este destino queda libre no puede bloquear a otro.

  Que reintente no significa que el error disappeared: cada vuelta vuelve a
  preguntar de verdad, y si no cabe se dice que no cabe.
  """
  @spec apply([map()], atom(), keyword(), (-> {:ok, map()} | {:error, term()}), reason()) ::
          {:ok, map()} | {:error, Error.t()}
  def apply(_messages, _consumer, config, intento, motivo) do
    config = Keyword.merge(defaults(), take_config(config))

    case Keyword.get(config, :strategy, @default_strategy) do
      :wait ->
        esperar(config, intento, deadline_ms(config), motivo)

      :fail ->
        {:error, error(motivo, retry_after_ms(wait_timeout_ms(nil, config), config))}

      # `:degrade` esta declarado en el tipo y no es alcanzable: para servir
      # con otro modelo «que cubra lo mismo» hay que saber **que pide la
      # pregunta** (enrutado por cobertura), y eso hoy no existe — degradar sin
      # eso seria adivinar. El raise lo dice aqui, y no un «desconocida»: quien
      # lo escriba en su configuracion se entera de que le falta a Candil, no
      # de que el se haya equivocado al teclear.
      :degrade ->
        raise ArgumentError,
              "el refusal :degrade no es alcanzable todavia: servir con otro " <>
                "modelo exige saber que pide la pregunta (enrutado por cobertura) " <>
                "y Candil no lo sabe. Usa :fail o :wait"

      otra ->
        raise ArgumentError,
              "estrategia de refusal desconocida: #{inspect(otra)}; " <>
                "usa :fail o :wait"
    end
  end

  defp esperar(config, intento, deadline, motivo) do
    restante = deadline - System.monotonic_time(:millisecond)

    if restante <= 0 do
      # El motivo que se agota el reloj es el **ultimo** que se vio, no uno
      # generico: quien mira el error quiere saber que no daba, y saber que no
      # daba es saber cual de las tres razones fue.
      {:error, error(motivo, retry_after_ms(wait_timeout_ms(nil, config), config))}
    else
      # Un tope de espera se mide en esperas cortas, no en una sola larga: el
      # motivo de estado tiene que reflejar la verdad en el momento en que se
      # pregunta, no como estaba hace `restante` ms.
      Process.sleep(min(250, restante))

      case intento.() do
        {:ok, decision} ->
          {:ok, decision}

        {:error, reason} ->
          if refusal_error?(reason),
            do: esperar(config, intento, deadline, reason),
            else: {:error, reason}
      end
    end
  end

  defp deadline_ms(config) do
    tope =
      case Keyword.get(config, :global_wait_timeout_ms) do
        nil -> wait_timeout_ms(nil, config)
        global -> min(wait_timeout_ms(nil, config), global)
      end

    System.monotonic_time(:millisecond) + tope
  end

  defp take_config(config) do
    Keyword.take(config, [:strategy, :wait_timeout_ms, :global_wait_timeout_ms, :retry_after_ms])
  end

  defp typical_latency_ms(%{typical_latency_s: segundos})
       when is_integer(segundos) and segundos > 0,
       do: segundos * 1_000

  defp typical_latency_ms(_otro), do: nil
end
