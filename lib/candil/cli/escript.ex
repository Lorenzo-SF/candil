defmodule Candil.CLI.Escript do
  @moduledoc """
  The escript entry point, and the only place `candil` decides anything before
  the DSL takes over.

  ## Aliases

  The DSL's `command/3` has no `aliases:` — only flags and arguments do. The
  short names people actually type (`-v`, `--version`, `model` for `models`)
  are therefore rewritten here, once, before dispatch. Declaring them as five
  extra `command/3` blocks would have put five phantoms in `candil --help`, and
  the help is supposed to be the declaration.

  ## Why the terminal decision is here and not in the DSL

  `Alaja.CLI.NoColor.sync/1` runs inside the generated `main/1` and only
  handles an explicit `--no-color`. The remaining answer is
  `Alaja.Config.color_enabled?/0`, which falls back to `IO.ANSI.enabled?/0` —
  and that function checks the `:elixir, :ansi_enabled` application env, *not*
  whether stdout is a terminal. Inside an escript that answer is `true`, so
  `candil doctor > report.txt` wrote escape codes into the file.

  That is why this module exists rather than trusting the framework: the
  decision is taken at the boundary, once, and handed to Alaja. Everything
  Alaja renders afterwards obeys it.
  """

  alias Candil.CLI
  alias Candil.CLI.Colorize

  @aliases %{
    "--version" => "version",
    "-v" => "version",
    "--help" => "help",
    "-h" => "help",
    "model" => "models"
  }

  @doc """
  Runs the CLI and returns the escript exit status.
  """
  @spec main([binary()]) :: :ok
  def main(argv) do
    terminal_policy!()
    CLI.main(expand(argv))
  end

  @doc """
  Rewrites the leading alias tokens, in place, leaving everything else alone.

  Only the first token can be an alias: `candil models remove --version` means
  a model called `--version`, not a request for the version.
  """
  @spec expand([binary()]) :: [binary()]
  def expand([first | rest]), do: [Map.get(@aliases, first, first) | rest]
  def expand([]), do: []

  # `NO_COLOR` is honoured first, then an actual terminal, then nothing. The
  # rule itself already exists in `Colorize`, which needs the same answer to
  # decide whether to colourise a `llama-server` log line. One rule, one place.
  defp terminal_policy! do
    Application.put_env(:alaja, :no_color, not Colorize.enabled?())
    :ok
  end
end
