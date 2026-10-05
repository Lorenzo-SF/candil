defmodule Candil.CLI.Colorize do
  @moduledoc """
  Colours a running `llama-server`'s output by pattern.

  Twenty-five lines, and they are what makes a 20 GB load legible: the first
  minute of a start is a wall of progress percentages, and the three lines that
  matter — the error, the throughput, and the moment the model is loaded — all
  look the same as the noise around them without this.

  ## Rules

  Red for the words that mean stop: OOM, CUDA errors, segfaults. Magenta for
  throughput, because that is the number you are waiting for. Green for the
  two lines that mean it worked.

  Anything unrecognised is passed through untouched. A colouriser that
  swallows or rewrites unknown output is a colouriser that will eventually
  hide the very error it was added to surface.
  """

  alias Alaja.Buffer
  alias Alaja.Components.Message
  alias Alaja.Printer, as: Say

  @rules [
    {:error, ~r/(OOM|out of memory|CUDA error|error|failed|segfault|abort)/i},
    {:magenta, ~r/(tok\/s|eval time|load time)/i},
    {:success, ~r/(server is listening|model loaded|main: server is listening|all model shards)/i}
  ]

  @doc """
  The level a line should be rendered at, or `nil` to leave it alone.

  Named after what it returns: a level, in Alaja's vocabulary
  (`:success | :warning | :error | :info`), not a colour. It used to return
  `:red`/`:green`/`:magenta` and the module carried a table of escape codes
  beside them, which is a private second answer to a question Alaja answers
  for the whole ecosystem.
  """
  @spec level_for(binary()) :: atom() | nil
  def level_for(line) when is_binary(line) do
    Enum.find_value(@rules, fn {colour, pattern} -> Regex.match?(pattern, line) && colour end)
  end

  @doc """
  The ANSI-wrapped line, or the line unchanged when nothing matches.

  A line with no colour is not padded, wrapped or touched in any way. A log
  is not ours to reformat.
  """
  @spec line(binary()) :: binary()
  def line(text) when is_binary(text) do
    case level_for(text) do
      nil ->
        text

      level ->
        # Alaja owns the escape sequences. They used to be a literal table of
        # "\e[31m" and friends in this file, which is a second, hand-rolled
        # answer to a question Alaja already answers — and one that does not
        # know about the `--no-color` conventions this CLI honours.
        text
        |> Message.render(level)
        |> Buffer.to_iodata()
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  A function to hand to a `:on_output` callback, one line at a time.
  """
  @spec printer() :: (binary() -> :ok)
  def printer, do: fn text -> Say.print_raw(line(text) <> "\n") end

  @doc """
  Whether the terminal can take ANSI at all.

  Checked once, because writing escape codes into a pipe or a log file makes
  the file harder to read than the uncoloured version would have been.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("NO_COLOR") do
      nil -> System.get_env("TERM") not in [nil, "", "dumb"]
      _ -> false
    end
  end
end
