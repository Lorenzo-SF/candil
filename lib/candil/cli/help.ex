defmodule Candil.CLI.Help do
  @moduledoc """
  What `candil` prints when it has nothing better to do.

  Exists from the first commit of the phase so that the escript never fails
  with a `FunctionClauseError` on a bare `candil`. A CLI with no help is a
  CLI that cannot be discovered, and the commands are the part a new user
  needs most.

  The **names** come from `Candil.CLI`, not from a list kept here. They were
  two lists kept here, and the second one was three commands short: `run`,
  `stop` and `status` worked and were invisible, which is the worst way for a
  command to be broken. A command you cannot find does not exist.
  """

  alias Candil.CLI

  # Only the prose is ours. The names come from the dispatch table, so a
  # command cannot exist without showing up in the help.
  @descriptions %{
    "version" => "Print the version and exit",
    "models" => "list, info, pull or remove models",
    "run" => "start a model: candil run <model> [--detach]",
    "stop" => "stop a model, or `stop all`",
    "status" => "what is running, and is it healthy",
    "doctor" => "check this machine and say how to fix it",
    "help" => "Print this"
  }

  @doc """
  The command table, in the order it is printed.

  The names come from the dispatch table, so adding a command to `Candil.CLI`
  makes it appear here without touching this module. A name with no
  description would render as a blank line, which is why the descriptions are
  a fallback and not the source of truth.
  """
  @spec commands() :: [{binary(), binary()}]
  def commands do
    CLI.commands()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{&1, Map.get(@descriptions, &1, "")})
  end

  @doc """
  Prints the usage line and the command table.
  """
  @spec run([binary()]) :: :ok
  def run(_argv \\ []) do
    IO.puts("Usage: candil <command> [args]")
    IO.puts("")
    IO.puts("Commands:")

    width = Enum.map(commands(), fn {name, _} -> String.length(name) end) |> Enum.max()

    Enum.each(commands(), fn {name, description} ->
      IO.puts("  #{String.pad_trailing(name, width)}  #{description}")
    end)

    :ok
  end
end
