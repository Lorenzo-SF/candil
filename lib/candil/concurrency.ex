defmodule Candil.Concurrency do
  @moduledoc """
  Fan-out, through `Arrea.Parallel`.

  One place to look when the next phase needs concurrency, and one place that
  knows how it fails. There is exactly one caller today —
  `candil models list`, which stats the filesystem twice per model and used to
  do it in series — and the point is that the second caller is a copy of the
  first instead of a fresh guess.

  ## Why `Arrea.Parallel` and not `Task.async_stream`

  Both are the same idea; the differences are the parts that are annoying to
  get right by hand every time. `Arrea.Parallel` enforces a per-task timeout
  rather than one global one, tags results so a caller does not have to
  correlate by position, and returns them in input order so a table does not
  reshuffle because two rows finished in a different order.

  ## What happens when it goes wrong

  A task that **raises** comes back as `{:error, %{error: e}}`, and this module
  **re-runs that task in series**, in the caller's process. A table missing a
  row because a filesystem call got in the way is worse than a table that took
  as long as it always did, so the fallback is the old behaviour, not a blank.

  A `throw` or an `exit` is *not* caught, on purpose. `Arrea.Parallel` rescues
  exceptions and does not trap throws, so a task that throws propagates — and
  that is the right answer: a `throw` is the task using control flow, not a row
  that failed. Swallowing it here would turn a caller's own signal into a
  silent retry.

  And under a threshold it does not spawn at all: `candil models list` with
  three models is not a fan-out, and starting four tasks to do three stats is
  overhead the user pays for nothing.
  """

  require Logger

  alias Arrea.Parallel

  # Below this, serial is faster than parallel. Four processes cost more than
  # the three `File.stat/1` calls they would have done at once.
  @min_tasks 4

  @typedoc "A labelled unit of work and its result."
  @type task :: {term(), (-> result)}
  @type result :: term()

  @doc """
  Runs `tasks` and returns `{label, value}` **in the order given**.

  Options are `Arrea.Parallel`'s: `:workers`, `:timeout`, `:ordered`.
  """
  @spec map([task()], keyword()) :: [{term(), result()}]
  def map(tasks, opts \\ [])

  def map([], _opts), do: []

  def map([{label, fun}], _opts) do
    # One task: a process would be pure ceremony.
    [{label, fun.()}]
  end

  def map(tasks, _opts) when length(tasks) < @min_tasks do
    Enum.map(tasks, fn {label, fun} -> {label, fun.()} end)
  end

  def map(tasks, opts) do
    labels = Enum.map(tasks, fn {label, _fun} -> label end)
    funs = Enum.map(tasks, fn {_label, fun} -> fun end)

    # No Arrea tag: `normalize_command/3` only accepts an **atom** as a tag, and
    # a label here is whatever the caller had — a model alias today, something
    # else tomorrow. Tagging would make the seam's contract "labels must be
    # atoms" for no gain, because `run_sync/2` is `ordered: true` and comes back
    # in input order anyway, so position is a safe correlation.
    funs
    |> Parallel.run_sync(opts)
    |> Enum.zip(labels)
    |> Enum.map(fn
      {{:ok, %{result: value}}, label} -> {label, value}
      {other, label} -> {label, retry(tasks, label, other)}
    end)
  end

  @doc """
  Whether `count` tasks are worth spreading across processes.
  """
  @spec parallel?(non_neg_integer()) :: boolean()
  def parallel?(count), do: count >= @min_tasks

  @doc """
  The threshold, so a caller can say why it did not fan out.
  """
  @spec min_tasks() :: pos_integer()
  def min_tasks, do: @min_tasks

  # The parallel attempt failed. Do the work the way it used to be done, in
  # this process, and say so — a silent per-row retry would look like the
  # fan-out had simply not helped.
  defp retry(tasks, tag, reason) do
    Logger.debug(
      "[Candil.Concurrency] la tarea #{inspect(tag)} fallo en paralelo (#{inspect(reason)}); " <>
        "se reintenta en serie, que es como se hacia antes"
    )

    case Enum.find(tasks, fn {label, _fun} -> label == tag end) do
      {_label, fun} -> fun.()
      nil -> nil
    end
  end
end
