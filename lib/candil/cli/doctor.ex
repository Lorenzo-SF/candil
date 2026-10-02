defmodule Candil.CLI.Doctor do
  @moduledoc """
  `candil doctor [--fix] [--json]`.

  Seven checks and a verdict. `--fix` attempts the one repair that is always
  safe — creating the data directory — and **lists what it could not do with
  the exact command**, because a `--fix` that silently gives up is worse than
  no `--fix` at all.

  Exit status is 0 when there are no errors and 1 otherwise, so a script can
  gate on it.
  """

  alias Candil.Doctor, as: Check

  @doc """
  Runs the command. Returns the exit status.
  """
  @spec run([binary()]) :: :ok | :error
  def run(argv) do
    opts = [fix: "--fix" in argv, json: "--json" in argv]
    report = Check.run(opts)

    if opts[:json] do
      IO.puts(Jason.encode!(report))
    else
      IO.puts(Check.render(report))
      IO.puts(unsolved(report))
    end

    if report.errors == 0, do: :ok, else: :error
  end

  defp unsolved(%{checks: checks}) do
    case Enum.reject(checks, &is_nil(&1.fix)) do
      [] ->
        ""

      pending ->
        "\nPara arreglar:\n" <>
          Enum.map_join(pending, "\n", fn %{name: name, fix: fix} -> "  #{name}: #{fix}" end)
    end
  end
end
