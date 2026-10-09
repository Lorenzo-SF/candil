defmodule Bench.Router do
  @moduledoc """
  Cuánto cuesta **decidir**.

  ## Por qué este es el benchmark que importa

  El diseño dice que un motor estático tiene que resolver la mayoría de las
  peticiones en **menos de 1 ms**, para que la latencia que se paga sea la del
  modelo y no la de Candil. Ese número estaba escrito en un documento desde la
  fase 7 y **nunca se había medido**.

  Y la consecuencia no es académica: la línea de cajas —cuántas peticiones se
  pueden encolar antes de que la GPU sea el cuello de botella— depende de cuánto
  cuesta cada decisión. Sin este número, la 8b se diseña a ojo.

  ## Cómo leerlo

  Si `decision completa` está por debajo de 1 ms, la política estática aguanta
  el camino caliente y el LLM puede quedar para el residuo. Si está en 10 ms,
  el cuello de botella es Candil y hay que encolar la decisión antes que el
  modelo, y eso cambia el diseño de la 8b entera.
  """

  alias Benchee
  alias Bench.Support
  alias Candil.Router

  # Benchee >= 1.5: `run/2` con una lista de TUPLAS `{nombre, funcion}`. No es
  # una lista de mapas con `:name` y `:fun`, que es lo que parece.
  @config [time: 5, warmup: 1, print: [fast_warning: false]]

  def run do
    Support.setup!()
    consumer = Support.consumer()

    jobs = [
      {"decision completa (3 prompts)",
       fn ->
         Enum.each(Support.prompts(), fn {_nombre, msgs} ->
           Router.route(msgs, consumer: consumer)
         end)
       end}
    ]

    jobs =
      jobs ++
        Enum.map(Support.prompts(), fn {nombre, msgs} ->
          {"decision - #{nombre}", fn -> Router.route(msgs, consumer: consumer) end}
        end)

    jobs =
      jobs ++
        [
          {"scoring por reglas (sin la decision)",
           fn ->
             Candil.Router.Scorer.rule_score(Support.codigo(), [:coder, :analyst, :verifier])
           end}
        ]

    Benchee.run(jobs, @config)
  end
end
