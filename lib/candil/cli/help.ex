defmodule Candil.CLI.Help do
  @moduledoc """
  The `help` command, delegating to the declaration.

  This module used to *be* the help: a `@descriptions` map of hand-kept strings
  and a table assembled from `String.pad_trailing/2`. Both are gone, and both
  were the drift. The descriptions now live in `Candil.CLI`, next to the flags
  they describe, where Alaja reads them for `--help` anyway — so a second copy
  here could only ever say something different from the truth.

  What is left answers `candil help` and exposes the declaration for the CI
  gate that compares it against what the help renders.
  """

  alias Alaja.Printer, as: Say
  alias Candil.CLI

  @doc """
  Prints the command reference.

  Delegates to the DSL's own empty-dispatch path — the same one bare `candil`
  and `--help` take — instead of assembling a second rendering of the same
  declaration.
  """
  @spec run(map() | keyword() | [binary()]) :: :ok
  def run(_arg \\ []) do
    # `:ok` regardless: `main/1` owns the exit status. If this returned the
    # DSL's value it would be `:ok` or an `ActionError`, and the caller would
    # be tempted to halve with it.
    _ = CLI.main([])
    :ok
  end

  @doc """
  Every declared command with its description, sorted by name.

  Read from the DSL rather than from a table here, so the CI gate that
  compares this against the dispatch table is comparing the declaration with
  the declaration, and the gate that checks descriptions is checking the text
  the user actually sees.
  """
  @spec commands() :: [{binary(), binary()}]
  def commands do
    CLI.__commands__()
    |> Enum.flat_map(fn command ->
      [
        {command.name, command.description}
        | Enum.map(command.subcommands, fn {name, sub} -> {to_string(name), sub.description} end)
      ]
    end)
    |> Enum.sort()
  end

  @doc """
  The commands the top-level help shows, with their descriptions.

  `commands/0` includes the subcommands too, which is right for "what can I
  run" and wrong for "does `--help` list what it can reach": `models list` is
  not missing from the top-level help, it is under `models`, which is. Two
  views, each honest about what it is comparing.
  """
  @spec top_level_commands() :: [{binary(), binary()}]
  def top_level_commands do
    CLI.__commands__()
    |> Enum.map(fn command -> {command.name, command.description} end)
    |> Enum.sort()
  end

  @doc false
  @spec warn_missing_description() :: :ok
  def warn_missing_description do
    for {name, description} <- commands(), description == "" do
      Say.print_warning("#{name} is declared with no description")
    end

    :ok
  end
end
