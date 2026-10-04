defmodule Candil.Doctor.FixTable do
  @moduledoc """
  The run-scoped holder for the `fix` each check worked out.

  A `candil doctor` run creates one of these, hands it to
  `Candil.Doctor.Checks`, and reads it back when building the report. The checks
  run in tasks, so a process dictionary would not survive to the caller; an ETS
  table does, and one row per check is the whole protocol.

  Every function tolerates `nil`, because a caller that only wants statuses
  should not have to know this exists. Writing to `nil` does nothing, and
  reading gives `nil` back — which is exactly right: no table, no fixes.
  """

  @type t :: :ets.table() | nil

  @doc """
  Creates a table for one run. The table is owned by the calling process and
  dies with it, so a `doctor` that crashes leaves nothing behind.
  """
  @spec new() :: t()
  def new, do: :ets.new(:candil_doctor_fixes, [:public, :set, read_concurrency: true])

  @doc """
  Records the fix for a check, if there is a table to record it in.
  """
  @spec put(t(), atom(), binary() | nil) :: :ok
  def put(nil, _id, _fix), do: :ok
  def put(table, id, fix), do: :ets.insert(table, {id, fix})

  @doc """
  Reads the fix for a check, or `nil` if it was never recorded.
  """
  @spec get(t(), atom()) :: binary() | nil
  def get(nil, _id), do: nil

  def get(table, id) do
    case :ets.lookup(table, id) do
      [{^id, fix}] -> fix
      [] -> nil
    end
  end
end
