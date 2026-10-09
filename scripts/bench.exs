# Corre TODOS los benchmarks.
#
#   mix bench              · todos
#   mix bench router       · solo el del router
#   mix bench chunker      · solo el del chunker
#   mix bench builder      · solo el del builder
#
# Que NO corran en el CI. Un benchmark es una medicion que se lee una vez y se
# pega en el documento del modulo; correrlo en cada push cuesta minutos y no
# avisa de nada. Y un umbral de rendimiento en el CI es la forma mas rapida de
# tener un gate que se cae por el ruido de una maquina compartida.
#
# Lo que SÍ esta en el CI son las puertas que se caen señalando un fichero:
# format, compile --warnings-as-errors, credo, test, dialyzer y el smoke del CLI.

base = Path.expand("../bench", __DIR__)

for fichero <- Path.wildcard(Path.join(base, "*.exs")) do
  Code.require_file(fichero)
end

todos = [
  {"router", Bench.Router, "cuánto cuesta decidir"},
  {"chunker", Bench.Chunker, "cuánto cuesta cortar"},
  {"builder", Bench.Builder, "cuánto cuesta construir el contexto"}
]

pedidos = System.argv()

seleccionados =
  if pedidos == [] do
    todos
  else
    Enum.filter(todos, fn {nombre, _, _} -> nombre in pedidos end)
  end

if seleccionados == [] do
  IO.puts("No hay benchmark con ese nombre. Los que hay:")

  for {nombre, _, para_que} <- todos do
    IO.puts("  #{String.pad_trailing(nombre, 10)} #{para_que}")
  end

  System.halt(1)
end

IO.puts("""

════════════════════════════════════════════════════════════════════════════════
 Candil · benchmarks
 #{length(seleccionados)} de #{length(todos)}
════════════════════════════════════════════════════════════════════════════════
""")

for {nombre, modulo, para_que} <- seleccionados do
  IO.puts("\n▸ #{nombre} — #{para_que}")
  modulo.run()
end

IO.puts("""

════════════════════════════════════════════════════════════════════════════════
 Los numeros de arriba hay que PEGARLOS en el documento del modulo.
 Un numero medido en un documento vale mas que un gate que nadie mira.
════════════════════════════════════════════════════════════════════════════════
""")
