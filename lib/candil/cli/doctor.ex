defmodule Candil.CLI.Doctor do
  @moduledoc """
  `candil doctor [--fix] [--json]`.

  Eight checks and a verdict. `--fix` attempts the one repair that is always
  safe — creating the data directory — and **lists what it could not do with
  the exact command**, because a `--fix` that silently gives up is worse than
  no `--fix` at all.

  Exit status is 0 when there are no errors and 1 otherwise, so a script can
  gate on it.

  ## Why Alaja

  The table, the coloured verdict and the "here is the command" lines are
  printed with `Alaja.Components.Table` and `Alaja.Printer`, like every other
  command of this CLI. Seven of the nine files here used to reach for
  `IO.puts`, which is how `candil models list` ended up rendering a table and
  `candil doctor` ended up rendering a hand-padded string: same library, same
  product, two different looks.

  `--json` goes through `Alaja.Printer.print_raw/2` on purpose. Raw means raw:
  no colour, no icon, no trailing decoration, so `jq '.[0].name'` keeps working
  — which is the entire point of having the flag.
  """

  alias Alaja.Components.{Header, Table}
  alias Alaja.Printer, as: Say
  alias Candil.Doctor, as: Check

  @doc """
  Runs the command. Returns the exit status.
  """
  @spec run(map() | keyword()) :: :ok | :error
  def run(parsed) do
    opts = [fix: flag(parsed, :fix), json: flag(parsed, :json)]
    report = Check.run(opts)

    if opts[:json] do
      # A LIST, not the report object. `jq '.[0].name'` is the whole point of
      # having --json, and an object would make it `.checks[0].name`.
      Say.print_raw(Jason.encode!(report.checks) <> "\n")
    else
      render(report)
    end

    if report.errors == 0, do: :ok, else: :error
  end

  defp flag(opts, key) when is_map(opts), do: Map.get(opts, key) == true
  defp flag(opts, key) when is_list(opts), do: Keyword.get(opts, key) == true

  defp render(report) do
    Header.print("candil doctor",
      subtitle: "comprobando esta maquina y diciendo como arreglarla",
      size: :medium
    )

    Table.print(
      headers: ["", "check", "que pasa"],
      rows: Enum.map(report.checks, &row/1),
      table_border: :rounded,
      headers_effects: [:bold],
      padding: 1
    )

    verdict(report)
    unsolved(report)
  end

  defp row(%{name: name, level: level, message: message}) do
    [mark(level), to_string(name), message]
  end

  # The mark is data in a table cell, not a printed icon: a table that coloured
  # one cell and left the rest plain is not a table. The colour comes from the
  # Table component; the glyph is the only thing left to say out loud.
  defp mark(:ok), do: "✓"
  defp mark(:warning), do: "⚠"
  defp mark(:error), do: "✗"

  defp verdict(%{errors: errors, warnings: warnings}) do
    message = "#{errors} errores · #{warnings} advertencias."

    case errors do
      0 -> Say.print_success(message)
      _ -> Say.print_error(message)
    end
  end

  defp unsolved(%{checks: checks}) do
    case Enum.reject(checks, &is_nil(&1.fix)) do
      [] ->
        :ok

      pending ->
        Say.print_warning("Para arreglar:")
        Enum.each(pending, &pending_line/1)
    end
  end

  defp pending_line(%{name: name, fix: fix}) do
    Say.print_raw("  #{name}: #{fix}\n")
  end
end
