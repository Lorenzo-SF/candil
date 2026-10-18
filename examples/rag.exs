# examples/rag.exs
#
# Index a text and search it.
#
# Run with:
#   CANDIL_DATA_DIR=~/.candil mix run examples/rag.exs
#
# No model needed: uses pre-computed embeddings for demonstration.

alias Candil.RAG

# Create an index
:ok = RAG.create_index("demo")

# Index some text with pre-computed embeddings
texts = [
  "Candil es un framework de IA para Elixir.",
  "El router decide que modelo responde cada peticion.",
  "Los agentes tienen memoria y circuit breakers."
]

embeddings = [
  [1.0, 0.0, 0.0],
  [0.0, 1.0, 0.0],
  [0.0, 0.0, 1.0]
]

{:ok, count} = RAG.index("demo", Enum.join(texts, " "), embeddings: embeddings)
IO.puts("Indexed #{count} chunks.")

# Search
{:ok, results} = RAG.search("demo", "que es candil", embedding: [1.0, 0.0, 0.0], limit: 2)
IO.puts("Results:")
Enum.each(results, fn chunk ->
  IO.puts("  - #{chunk.text} (score: #{Float.round(chunk.score, 3)})")
end)

RAG.drop_index("demo")
IO.puts("Done.")
EOF