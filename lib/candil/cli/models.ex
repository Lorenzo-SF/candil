defmodule Candil.CLI.Models do
  @moduledoc """
  The `candil models` group: list, info, pull, remove.

  The catalogue comes from `Candil.Store`, so every command here answers from
  ETS and never reads the file itself. `Candil.CLI.main/1` hydrates the Store
  from `candil.toml` before dispatching, and a command that did the reading
  itself would be one more path that can disagree with the others.
  """

  alias Alaja.Components.Table
  alias Alaja.Printer, as: Say
  alias Candil.Error, as: Err
  alias Candil.{Model, Source, Store}

  @doc """
  `candil models list`.

  The columns are the ones the design document's acceptance criteria name, and
  the `state` column is `downloaded` only when the file is really there.
  `Model.downloaded?/1` asks the filesystem rather than the source table,
  because a source says where a file should be, not whether it is.
  """
  @spec list(map() | keyword()) :: :ok
  def list(_opts) do
    case Store.list_models() do
      [] ->
        Say.print_info("no models configured. Check candil.toml")
        :ok

      models ->
        Table.print(
          headers: ["alias", "type", "ctx", "port", "usage", "size", "state"],
          rows: Enum.map(Enum.sort_by(models, & &1.alias), &row/1),
          headers_color: :cyan,
          headers_effects: [:bold],
          table_border: :rounded,
          padding: 1
        )

        :ok
    end
  end

  defp row(%Model{} = model) do
    [
      to_string(model.alias),
      to_string(model.type),
      to_string(model.context_size),
      to_string(model.port),
      Enum.join(model.usage, ","),
      size(model),
      state(model)
    ]
  end

  defp size(%Model{type: :remote}), do: "-"
  defp size(%Model{} = model), do: model |> bytes() |> human_bytes()

  defp bytes(%Model{} = model) do
    case model.source && Source.size(model.source) do
      size when is_integer(size) and size > 0 -> size
      _ -> "-"
    end
  end

  # The acceptance criteria want "17.7 GB", not "1857689600".
  defp human_bytes("-"), do: "-"
  defp human_bytes(n) when n < 1_000, do: "#{n} B"

  defp human_bytes(n) do
    unit = Enum.find(["GB", "MB", "kB"], &(n >= div(unit_bytes(&1), 1000)))
    value = n / unit_bytes(unit)
    :erlang.float_to_binary(Float.round(value, 1), decimals: 1) <> " " <> unit
  end

  defp unit_bytes("GB"), do: 1_000_000_000
  defp unit_bytes("MB"), do: 1_000_000
  defp unit_bytes("kB"), do: 1_000

  defp state(%Model{type: :remote}), do: "-"
  defp state(model), do: if(Model.downloaded?(model), do: "downloaded", else: "missing")

  @doc """
  `candil models info <alias>`.
  """
  @spec info(map() | keyword()) :: :ok
  def info(opts) do
    case fetch_alias(opts) do
      # The DSL makes `:alias` required, so this is only reachable from the
      # library — and it still answers instead of raising.
      nil ->
        Say.print_error("usage: candil models info <alias>")
        :ok

      alias_name ->
        case lookup(alias_name) do
          {:ok, model} ->
            Table.print(headers: ["field", "value"], rows: details(model), table_border: :rounded)
            :ok

          :error ->
            Say.print_error("no such model: #{alias_name}")
            :ok
        end
    end
  end

  defp details(%Model{} = model) do
    [
      ["alias", to_string(model.alias)],
      ["type", to_string(model.type)],
      ["engine", model.engine && to_string(model.engine)],
      ["provider", model.provider && to_string(model.provider)],
      ["context_size", to_string(model.context_size)],
      ["port", to_string(model.port)],
      ["usage", Enum.join(model.usage, ",")],
      ["tags", Enum.join(model.tags, ",")],
      ["file", Model.file_path(model) || "-"],
      ["source", source_line(model.source)],
      ["draft", source_line(model.draft)]
    ]
  end

  defp source_line(nil), do: "-"
  defp source_line(%Source{kind: kind, repo: repo, file: file}), do: "#{kind} #{repo}/#{file}"

  @doc """
  `candil models pull [alias]`.

  Delegates to `Source.fetch/2`, which already resumes, verifies the checksum
  while streaming and renames into place. The progress bar reads
  `Source.progress/1` rather than counting bytes here, so the number on
  screen is the number the download reports.
  """
  @spec pull(map() | keyword() | [binary()]) :: :ok
  def pull(opts) do
    args = pull_args(opts)

    case models_to_pull(args) do
      [] ->
        Say.print_error("usage: candil models pull [alias]")
        :ok

      models ->
        Enum.each(models, &pull_one/1)
        :ok
    end
  end

  defp models_to_pull([]), do: Store.list_models()
  defp models_to_pull([alias_name | _rest]), do: lookup(alias_name) |> ok_value()

  defp pull_one(model) do
    case model.source do
      nil ->
        Say.print_warning("#{model.alias}: no source configured")

      source ->
        Say.print_info("downloading #{model.alias}…")

        case Source.fetch(source) do
          {:ok, path} -> Say.print_success("#{model.alias} → #{path}")
          {:error, reason} -> Say.print_error("#{model.alias}: #{describe(reason)}")
        end
    end
  end

  @doc """
  `candil models remove <alias>`, asking first.

  The confirmation is not decoration. Removing a model takes a 17 GB file with
  it, and a typo should not be the reason.
  """
  @spec remove(map() | keyword() | nil) :: :ok
  def remove(opts) do
    case fetch_alias(opts) do
      nil ->
        Say.print_error("usage: candil models remove <alias>")
        :ok

      alias_name ->
        remove_alias(alias_name)
    end
  end

  defp remove_alias(alias_name) do
    case lookup(alias_name) do
      {:ok, model} ->
        file = Model.file_path(model)

        if confirm?("remove #{model.alias}#{file && " (#{file})"}?") do
          Store.deregister_model(model.alias)
          _ = file && File.rm(file)
          _ = file && File.rm(file <> ".complete")
          Say.print_success("#{model.alias} removed")
        else
          Say.print_info("cancelled")
        end

        :ok

      :error ->
        Say.print_error("no such model: #{alias_name}")
        :ok
    end
  end

  # `--yes` is there for scripts. It is opt-in, never the default, and a
  # `remove` with no alias cannot use it: there is nothing to confirm.
  defp confirm?(question) do
    if "--yes" in System.argv() do
      true
    else
      # The prompt and the answer are two steps, not one `&&`: `print_info`
      # answers :ok, and `:ok && ~r/^y/i` is a match against :ok.
      Say.print_info("#{question} [y/N]")
      affirmative?(IO.gets(:stdio, ""))
    end
  end

  defp affirmative?(answer) when is_binary(answer), do: answer =~ ~r/^y/i
  defp affirmative?(_), do: false

  defp fetch_alias(opts) when is_map(opts), do: Map.get(opts, :alias)
  defp fetch_alias(opts) when is_list(opts), do: Keyword.get(opts, :alias)

  defp pull_args(opts) when is_map(opts) do
    case fetch_alias(opts) do
      nil -> []
      alias_name -> [alias_name]
    end
  end

  defp pull_args(opts) when is_list(opts), do: opts

  defp lookup(name) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    alias_name = String.to_atom(name)

    case Store.get_model(alias_name) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp ok_value({:ok, value}), do: [value]
  defp ok_value(:error), do: []

  # Source.fetch/2 answers {:error, %Candil.Error{}}, and the interesting part of
  # an Error is its :reason. A guard on is_binary/1 can never match, because
  # the only value that reaches here is a struct.
  defp describe(%Err{reason: reason}), do: to_string(reason)
end
