# examples/chat.exs
#
# The simplest thing that works: chat with a local model.
#
# Run with:
#   CANDIL_DATA_DIR=~/.candil mix run examples/chat.exs
#
# Prerequisites:
#   - candil.toml configured with at least one model
#   - the model downloaded (`candil models pull <alias>`)
#
# The engine starts automatically if it is not running.

alias Candil

{:ok, response} = Candil.chat("vision", "Di hola y nada mas.")
IO.puts("Response: #{response.content}")
IO.puts("Tokens: #{response.usage.total_tokens}")
EOF