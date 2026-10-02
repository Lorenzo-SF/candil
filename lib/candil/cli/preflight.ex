defmodule Candil.CLI.Preflight do
  @moduledoc """
  The four questions asked before a port is touched.

  A start that cannot work must fail *before* it claims a port, not halfway
  through spawning a `llama-server` that has nothing to load. The order is the
  design document's (§11.2): the model file, the engine, the binary, and
  whether the source has actually been fetched.

  Every check returns a reason that names what is missing, because "engine
  failed to start" is not something a user can act on.
  """

  alias Candil.{Build, Engine, Model, Store}

  @doc """
  Runs every check. `{:ok, engine}` or `{:error, [reasons]}`.
  """
  @spec run(atom(), keyword()) :: {:ok, Engine.t()} | {:error, [binary()]}
  def run(model_alias, _opts \\ []) do
    with {:ok, model} <- fetch_model(model_alias),
         {:ok, engine} <- fetch_engine(model) do
      case problems(model, engine) do
        [] -> {:ok, engine}
        reasons -> {:error, reasons}
      end
    end
  end

  defp fetch_model(alias_name) do
    case Store.get_model(alias_name) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> {:error, ["no such model: #{alias_name}"]}
    end
  end

  # The registered engine, not a fresh empty one. A `%Engine{alias: :e}` has
  # no `binary`, so every preflight answered "no binary" no matter what the
  # catalogue said — and the test that would have caught it was the one with
  # no engine registered at all.
  defp fetch_engine(%Model{type: type, engine: alias_name}) when type in [:remote, :external],
    do: {:ok, %Engine{alias: alias_name}}

  defp fetch_engine(%Model{engine: nil}), do: {:error, ["model has no engine"]}

  defp fetch_engine(%Model{engine: alias_name}) do
    case Store.get_engine(alias_name) do
      {:ok, engine} -> {:ok, engine}
      {:error, :not_found} -> {:error, ["no such engine: #{alias_name}"]}
    end
  end

  defp problems(model, engine) do
    file_problem(model) ++ engine_problem(engine)
  end

  defp file_problem(%Model{type: :remote}), do: []
  defp file_problem(%Model{type: :external}), do: []

  defp file_problem(%Model{} = model) do
    cond do
      Model.downloaded?(model) ->
        []

      is_nil(model.source) ->
        ["#{model.alias}: no file and no source; run `candil models pull`"]

      true ->
        ["#{model.alias}: #{Model.file_path(model)} is not there; run `candil models pull`"]
    end
  end

  defp engine_problem(%Engine{binary: nil}), do: ["engine has no binary"]

  defp engine_problem(%Engine{binary: path} = engine) do
    if File.exists?(path), do: [], else: missing_binary(engine, path)
  end

  # An engine with an install plan is not broken, it is unbuilt. That is a
  # different message from "the binary is not there", and it names the command
  # that fixes it — which is the whole point of asking before touching a port.
  defp missing_binary(%Engine{install: %Build{} = install}, path) do
    ["#{path} is not built; run `candil engine install` for #{install.strategy}"]
  end

  defp missing_binary(_engine, path), do: ["binary not found: #{path}"]

  @doc """
  Whether a build plan exists for the engine, which is what makes a missing
  binary a "not built yet" rather than a failure.
  """
  @spec installable?(Model.t()) :: boolean()
  def installable?(%Model{engine: nil}), do: false

  def installable?(%Model{engine: alias_name}),
    do: alias_name != nil and engine_known?(alias_name)

  defp engine_known?(alias_name) do
    case Store.get_engine(alias_name) do
      {:ok, %Candil.Engine{install: %Build{}}} -> true
      _ -> false
    end
  end
end
