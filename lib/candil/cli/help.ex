defmodule Candil.CLI.Help do
  @moduledoc """
  What `candil` prints when it has nothing better to do.

  Exists from the first commit of the phase so that the escript never fails
  with a `FunctionClauseError` on a bare `candil`. A CLI with no help is a
  CLI that cannot be discovered, and the commands are the part a new user
  needs most.

  The list is a data structure rather than a string, because the same list
  has to end up in `mix help` and in the README eventually, and two copies of
  the same list is a list that lies in one of them.
  """

  @commands [
    {"version", "Print the version and exit"},
    {"models", "list, info, pull or remove models"},
    {"help", "Print this"}
  ]

  @doc """
  Prints the usage line and the command table.
  """
  @spec run([binary()]) :: :ok
  def run(_argv \\ []) do
    IO.puts("Usage: candil <command> [args]")
    IO.puts("")
    IO.puts("Commands:")

    width = Enum.map(@commands, fn {name, _} -> String.length(name) end) |> Enum.max()

    Enum.each(@commands, fn {name, description} ->
      IO.puts("  #{String.pad_trailing(name, width)}  #{description}")
    end)

    :ok
  end

  @doc """
  The command list, for anything that wants to render it differently.
  """
  @spec commands() :: [{binary(), binary()}]
  def commands, do: @commands
end
