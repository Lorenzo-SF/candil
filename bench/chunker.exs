defmodule Bench.Chunker do
  @moduledoc """
  Cuánto cuesta cortar un documento.

  ## Por qué

  El corte no esta en el camino caliente —cada documento se corta una vez— pero
  **indexar 40.000 chunks** es una operacion que tarda, y mientras tarda no se
  puede indexar nada. Es el trabajo de fondo del RAG.

  Y el `:fixed` con solape es el caso Caro: solapa ventana y ventana, asi que
  hace mas trabajo por palabra que los otros dos. Si el solape se pone ahi sin
  medir, nadie sabe lo que cuesta.

  ## Lo que se compara

  Los tres modos sobre el MISMO texto, y ademas el `:fixed` con solape, porque es
  el unico que hace trabajo extra.
  """

  alias Benchee
  alias Candil.RAG.Chunker

  @config [time: 5, warmup: 1]

  @documento String.duplicate(
               "La biblioteca municipal ofrece prestamo de documentos. " <>
                 "El periodo de renovacion es de treinta dias. " <>
                 "Los documentos deben estar en buen estado. ",
               300
             )

  def run do
    jobs =
      Enum.map(Chunker.strategies(), fn estrategia ->
        {"chunker - #{estrategia}", fn -> Chunker.chunk(@documento, strategy: estrategia) end}
      end)

    jobs =
      jobs ++
        [
          {"chunker - fixed CON solape de 50%",
           fn -> Chunker.chunk(@documento, strategy: :fixed, size: 200, overlap: 100) end}
        ]

    Benchee.run(jobs, @config)
  end
end
