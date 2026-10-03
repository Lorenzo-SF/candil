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

  alias Alaja.Output
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

  ## Why the translation is here

  An escript's exit status is its `main/1` return value, and **only if that
  value is an integer** — anything else is 0. The DSL's `main/1` returns
  whatever a handler returned, and handlers return `:ok` or `:error`, which are
  atoms. So before this, `candil doctor` on a machine with no engine binary
  printed a report full of failures and exited **0**: a CI pipeline running it
  went green on a broken machine, and no amount of reading the output would have
  caught it, because the output is a table and a table has no exit code.

  Translating at the boundary is the right place for it: handlers keep
  returning the meaningful atom (which is what they are tested against), and the
  shell gets the number it can branch on.
  """
  @spec main([binary()]) :: no_return()
  def main(argv) do
    terminal_policy!()
    status = argv |> expand() |> CLI.main() |> exit_status()

    # `System.halt/1`, and not `return status`.
    #
    # An escript's exit status is set by *halting* with it. Returning an integer
    # from `main/1` does nothing: the generated wrapper calls `halt(0)` on the
    # way out, whatever came back. That is why `candil doctor` could print a
    # report full of failures and exit 0 while `candil run` exited 1 — the
    # second one is Alaja's own usage error, which halts the process itself.
    #
    # Halting here rather than turning on the DSL's `halt_on_error` is the
    # difference between the binary and the library. This module only ever runs
    # as the escript entry point; a host that embeds Candil calls
    # `Candil.CLI.main/1`, which returns a value and never halts anything.
    System.halt(status)
  end

  # 2 and above are reserved for Alaja's own usage errors: a wrong flag or a
  # missing required argument is a mistake in the *command line*, not a failure
  # of the thing the command was asked to do. `run` without a model exits 1
  # because the DSL treats it as usage; a command that ran and failed exits 1
  # too, because from a script's point of view both are "it did not do what I
  # asked". The distinction is kept in the message, which is where it is useful.
  @doc false
  @spec exit_status(term()) :: non_neg_integer()
  def exit_status(0), do: 0
  def exit_status(status) when is_integer(status), do: status
  def exit_status(:error), do: 1
  def exit_status({:error, _reason}), do: 1
  def exit_status(_), do: 0

  @doc """
  Answers a command that does not exist.

  Wired as the DSL's `catch_all`, so it runs instead of Alaja's
  `ErrorHandler.unknown_command/2`. Two reasons, and the second is the one that
  matters: it can suggest the command the user probably meant, and it returns
  `:error`, which `exit_status/1` turns into exit 1. The framework's handler
  prints a perfectly good error and returns `:ok`, so `candil frobnicate`
  exited **0** — a script could not tell a typo from success.
  """
  @spec unknown(map()) :: :error
  def unknown(%{name: name}) do
    # `Alaja.Output.write_error/1`, not `Alaja.Printer.print_error/2`. The
    # printer writes to stdout, and a command that failed saying so on stdout
    # lands in the middle of whatever a script was capturing — `candil
    # something --json` would put an error in the middle of its JSON. Alaja's
    # output module is the one that resolves `:stderr` correctly, including the
    # daemon case, and that is the same thing the DSL uses for its own dispatch
    # errors.
    Output.write_error("unknown command: #{name}")

    Output.write_raw_error("los comandos son: " <> Enum.join(CLI.command_names(), ", ") <> "\n")
    :error
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
