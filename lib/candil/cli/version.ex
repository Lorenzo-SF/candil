defmodule Candil.CLI.Version do
  alias Alaja.Printer, as: Say

  @moduledoc """
  The `candil version` command.

  Trivial on purpose: it is the one command that needs no catalogue, no
  configuration and no network, which makes it the honest way to prove the
  escript path works. If `candil version` does not print, nothing else will.

  ## The version, and where it comes from

  From `Application.spec(:candil, :vsn)` at runtime, not from a constant
  here. A hardcoded version in a CLI is a version that is wrong from the day
  the next release ships, and nobody notices until a bug report says so.

  ## Examples

      iex> Candil.CLI.Version.render("4.1.2")
      "Candil 4.1.2"
  """

  @doc """
  Runs the command and returns `:ok`.
  """
  @spec run([binary()]) :: :ok
  def run(_argv \\ []) do
    Say.print_raw(render(version()) <> "\n")
    :ok
  end

  @doc """
  The version of the running application, or `"unknown"` when it is not
  loaded. The fallback is there because this is also reachable from `iex -S
  mix` in an environment where the app spec is not what you expect, and a
  version command that crashes is worse than one that admits ignorance.
  """
  @spec version() :: binary()
  def version do
    case Application.spec(:candil, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  The line `version` prints.
  """
  @spec render(binary()) :: binary()
  def render(version), do: "Candil #{version}"
end
