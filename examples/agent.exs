# examples/agent.exs
#
# A reflex agent that answers a question using a real model.
#
# Run with:
#   CANDIL_DATA_DIR=~/.candil mix run examples/agent.exs
#
# Prerequisites:
#   - candil.toml configured with at least one model
#   - the model downloaded (`candil models pull <alias>`)

alias Candil
alias Candil.Agents.SimpleReflex

{:ok, pid} = Candil.Agents.Supervisor.start_agent(SimpleReflex,
  name: "example-agent",
  goal: "Responde en una sola frase, en espanol.",
  backend: Candil.Backend.LlamaCpp,
  model: "vision",
  max_steps: 3,
  timeout: 120_000
)

IO.puts("Agent started.")

{:ok, answer, trace} = SimpleReflex.evaluate(pid, "Que es Candil?")
IO.puts("Answer: #{answer}")
IO.puts("Steps: #{length(trace)}")

Candil.Agents.Supervisor.stop_agent(pid)
IO.puts("Done.")
EOF