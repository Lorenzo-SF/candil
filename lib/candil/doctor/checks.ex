defmodule Candil.Doctor.Checks do
  @moduledoc """
  The eight checks, as `Botica` check definitions.

  This is the adapter, and it is deliberately thin: the checks themselves stay
  in `Candil.Doctor` where they are already written and tested, and what lives
  here is only the translation into `t:Botica.Types.check_def/0`.

  ## What Botica takes over

  By handing the definitions to `Botica.Doctor.run/2`, Candil stops owning the
  part it never actually wrote well — the running. `Botica.Runner.Executor`
  gives:

    * **Real parallelism.** The eight checks run through `Task.async_stream`
      with a concurrency cap, and a slow one stops the others. Candil ran them
      in sequence, so `candil doctor` cost the sum of the eight.
    * **A timeout per check**, applied to each one, instead of a single hope.
    * **Crash isolation, with the message.** A check that raises becomes
      `{:error, ...}` for itself and the other seven still run — which is the
      "one check, one crash" rule `Candil.Doctor` had been enforcing by hand
      with a `rescue` around each call.
    * **Ordering.** The executor uses `ordered: true`, so the results come back
      in declaration order. `priority` is the declaration order, and
      `Candil.Doctor` does not rely on either — it sorts by `:id` against its
      own list, because a report whose order depends on a sibling library's
      internals is one that changes under you.

  ## The `fix` field, and why there is a table

  Botica carries `fix_command` on the *definition*, and a definition is built
  before its check has run — but Candil's `fix` is only knowable afterwards.
  `candil doctor` says `candil engine install  (estrategia source)`, and the
  strategy comes from the check.

  So each check writes its own `fix` into a private, run-scoped ETS table as it
  runs, and `Candil.Doctor` reads them back after. The alternatives were worse:
  duplicating the logic in a `fix_hint/1` would let the two answers drift apart,
  and putting the fix into the *message* would change text that tests and users
  read. The table is five lines and cannot drift, because there is only one copy
  of the logic.
  """

  alias Candil.Doctor, as: Check
  alias Candil.Doctor.FixTable

  @ordered [
    {:config, 1, "Edit candil.toml, o deja que `candil doctor --fix` lo cree"},
    {:binary, 2, "candil engine install"},
    {:sources, 3, "candil models pull"},
    {:ports, 4, "nothing to run: the ports in use belong to another process"},
    {:auth, 5, "export the API key the provider needs"},
    {:gpu, 6, "nothing to do: without a GPU the models run on the CPU"},
    {:memory, 7, "close something, or give Candil a model that fits"},
    {:disk, 8, "free some space where the models live"}
  ]

  @doc """
  All eight check definitions, in the order `candil doctor` has always printed
  them.

  `table` is the run-scoped ETS table the checks write their `fix` into; see the
  moduledoc. Pass `nil` to build definitions that report no fixes at all, which
  is what a caller that only wants statuses needs.
  """
  @spec all(:ets.table() | nil) :: [Botica.Types.check_def()]
  def all(table \\ nil) do
    Enum.map(@ordered, fn {id, priority, fallback_fix} ->
      definition(id, priority, fallback_fix, table)
    end)
  end

  @doc """
  The `fix` function for the config check, and the only one that has one.

  `candil doctor --fix` makes the directories the tool needs. That is not
  `Botica`'s kind of repair — `Botica.Repair.Fixer` only attempts a fix on a
  check that came back `:error`, and a missing `candil.toml` is a *warning*,
  so a Fixer-only `--fix` would quietly do nothing on the machine that most
  needs it. The function is exposed here anyway so that a config problem that
  *is* an error gets repaired through the same path.
  """
  @spec config_fix() :: {:ok, binary()} | {:error, binary()}
  def config_fix, do: Check.prepare()

  @doc """
  The check ids, in order. `Candil.Doctor` sorts against this rather than
  trusting an executor's internals.
  """
  @spec ids() :: [atom()]
  def ids, do: Enum.map(@ordered, &elem(&1, 0))

  # One builder for all eight. The `fun` is Candil's own check, unchanged, and
  # the wrapping is: run it, keep its `fix` somewhere the caller can find it,
  # and hand Botica the `{status, message}` it knows how to carry.
  defp definition(id, priority, fallback_fix, table) do
    %{
      id: id,
      name: to_string(id),
      description: "#{id} is healthy",
      priority: priority,
      tags: [:candil],
      timeout: nil,
      check: fn -> probe(id, table, fallback_fix) end,
      fix: fix_for(id),
      fix_command: fallback_fix
    }
  end

  defp fix_for(:config), do: &__MODULE__.config_fix/0
  defp fix_for(_id), do: fn -> :skipped end

  defp probe(id, table, _fallback_fix) do
    %{level: level, message: message, fix: fix} = Check.run_one(id)
    # Exactly what the check said, including `nil`. A check that passed has no
    # fix, and inventing one — "run `candil doctor`" is always technically true
    # of a failing machine — turns a clean report into a list of instructions
    # the user does not need. The static hint stays on the definition as
    # `fix_command`, which is Botica's own metadata and which this module does
    # not read.
    FixTable.put(table, id, fix)
    {level, message}
  rescue
    # The same guarantee `Candil.Doctor.probed/1` gave, kept here because
    # `Botica`'s executor catches a crash too — but it reports the *exit
    # reason*, which is `{%RuntimeError{}, stacktrace}` and unreadable in a
    # table. Catching it here turns a crash into the sentence it should have
    # been all along.
    error ->
      FixTable.put(table, id, nil)
      {:error, "el check revienta: " <> Exception.message(error)}
  end
end
