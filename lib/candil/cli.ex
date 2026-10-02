defmodule Candil.CLI do
  @moduledoc """
  Entry point for the `candil` command line.

  The whole public surface is `main/1` and `run/1`. Alaja does the parsing, the
  tables, the colours and the error rendering; this module decides what a
  command name means and hands over.

  ## Why `main/1` starts the application first

  The catalogue lives in ETS, owned by processes in the supervision tree. A
  command that runs before `Candil.Application` is up looks at empty tables
  and reports an empty catalogue, which looks exactly like a configuration
  problem. It is not a configuration problem. The design document flags this
  as the detail that is forgotten every time, so it is in the first function
  rather than in a comment somewhere else.

  ## Commands are a table, not a `case`

  Adding a command is one line here. That matters more than it sounds: the
  first cut of this module was a `case` with the command modules spelled out
  at each branch, and the name `Version` collided with Elixir's own `Version`
  the moment it was aliased. A table of module values has neither problem,
  and it is the shape the help command reads too.
  """

  # The command table, and the spellings that reach it. The bare word comes
  # first in each list because it is what a person types; the flags are what
  # a script and a habit type. Having only the flags means the common one
  # falls through to the help and looks like a broken binary.
  @commands %{
    "version" => {Candil.CLI.Version, ["version", "--version", "-v"]},
    "help" => {Candil.CLI.Help, ["help", "--help", "-h"]},
    "models" => {Candil.CLI.Models, ["models", "model"]},
    "run" => {Candil.CLI.Lifecycle, ["run"]},
    "stop" => {Candil.CLI.Lifecycle, ["stop"]},
    "status" => {Candil.CLI.Lifecycle, ["status"]},
    "doctor" => {Candil.CLI.Doctor, ["doctor"]}
  }

  @default "help"

  @doc """
  Runs the CLI with `argv` and returns the exit status.

  An escript `main/1` has to answer with a status code, not a value, so this
  is the only function shaped for the escript entry point.
  """
  @spec main([binary()]) :: :ok
  def main(argv) do
    {:ok, _apps} = Application.ensure_all_started(:candil)
    run(argv)
  end

  @doc """
  Resolves `argv` to a command and runs it.

  Anything unrecognised lands on the help, because a CLI that crashes on a
  typo teaches nobody the right spelling.
  """
  @spec run([binary()]) :: :ok
  def run(argv) do
    {module, _} = Map.fetch!(@commands, canonical(argv))
    module.run(rest(argv))
  end

  # `models` and `stop` are groups: `candil models list` needs the subcommand,
  # not the group name, passed on. `run` and `status` need their arguments.
  defp rest(argv) do
    case Map.fetch!(@commands, canonical(argv)) do
      {Candil.CLI.Models, _} -> Enum.drop(argv, 1)
      _ -> argv
    end
  end

  @doc false
  def dispatch(argv), do: run(argv)

  @doc """
  The command table, for `mix help` and for anything that wants to render it
  differently.
  """
  @spec commands() :: %{binary() => {module(), [binary()]}}
  def commands, do: @commands

  defp canonical(argv) do
    case List.first(argv) do
      nil ->
        @default

      word ->
        Enum.find_value(@commands, @default, fn {name, {_m, spellings}} ->
          word in spellings && name
        end)
    end
  end
end
