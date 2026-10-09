defmodule Bench.Builder do
  @moduledoc """
  Cuánto cuesta construir el contexto de una petición.

  ## Por qué

  El `Builder` va en el camino de **cada** petición: mira el presupuesto,
  decide qué turnos entran y avisa si no cabe. Es la parte de Candil que se
  ejecuta aunque el modelo conteste en un milisegundo.

  Y tiene tres salidas que miden cosas distintas:
  - `:strict` que cabe: el caso normal
  - `:strict` que **no** cabe: el caso que produce un error
  - `:compact` que recorta: el caso de la cola

  La tercera de la lista es la interesante, porque es la única que devuelve un
  error, y porque es la que decide si el historial se recalcula entero o se
  recorta por el camino.

  ## Ojo con la API de la sesión

  `Context.Session.new/2` es `(consumer, id)`, **no** `(id, opts)`. La ventana
  de contexto va en `Context.Builder.build/3`, y eso es lo que se compara aquí.
  """

  alias Benchee
  alias Candil.Context

  @config [time: 5, warmup: 1]

  def run do
    sesion = sesion(50, :ancha)
    ajustada = sesion(50, :estrecha)

    jobs = [
      {"builder - 50 turnos, ventana de 131072",
       fn -> Context.Builder.build(sesion, [turno("hola")], context_size: 131_072) end},
      {"builder - 50 turnos en ventana de 8192 (:strict)",
       fn ->
         Context.Builder.build(ajustada, [turno("hola")],
           context_size: 8_192,
           context_policy: :strict
         )
       end},
      {"builder - el mismo recortando (:compact)",
       fn ->
         Context.Builder.build(ajustada, [turno("hola")],
           context_size: 8_192,
           context_policy: :compact
         )
       end}
    ]

    Benchee.run(jobs, @config)
  end

  # 50 turnos de ida y vuelta, con contenido de tamano realista.
  defp sesion(turnos, _etiqueta) do
    session = Context.Session.new(:builder_bench, "sesion_#{turnos}")

    Enum.reduce(1..turnos, session, fn i, acc ->
      acc =
        Context.Session.add_message(
          acc,
          "user",
          "mensaje #{i}: " <> String.duplicate("contenido ", 20)
        )

      Context.Session.add_message(acc, "assistant", "respuesta #{i}")
    end)
  end

  defp turno(texto), do: %{role: "user", content: texto}
end
