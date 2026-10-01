defmodule Candil.Config.Schema do
  @moduledoc """
  Validation for the `candil.toml` document.

  The TOML file is the source of truth; `config.exs` still works and is
  applied first, with the file overwriting it. That order matters when someone
  has both: the file is the newer mechanism, so it wins.

  Validation is by hand rather than by macro, because the errors have to name
  the thing that is wrong in the user's terms — `model 'coder' has no port`
  is actionable, and a `NimbleOptions` message about a nested key path is
  not. Every function returns a list of problems rather than the first one, so
  a user fixing a config file sees all of it in one pass.
  """

  @sections ~w(general engine model provider consumer)

  @doc """
  Validates a decoded TOML document.

  Returns `{:ok, config}` or `{:error, problems}`.

  ## Examples

      iex> Candil.Config.Schema.validate(%{"general" => %{"data_dir" => "/tmp"}})
      {:ok, %{"general" => %{"data_dir" => "/tmp"}}}

      iex> {:error, problems} = Candil.Config.Schema.validate(%{"engine" => "nope"})
      iex> Enum.any?(problems, &String.contains?(&1, "engine"))
      true
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [binary()]}
  def validate(config) when is_map(config) do
    case check_sections(config) do
      [] -> {:ok, config}
      problems -> {:error, problems}
    end
  end

  def validate(other),
    do: {:error, ["candil.toml must decode to a table, got: #{inspect(other)}"]}

  defp check_sections(config) do
    Enum.flat_map(@sections, fn section ->
      case Map.get(config, section) do
        nil -> []
        value when is_map(value) -> validate_section(section, value)
        other -> ["#{section} must be a table of entries, got: #{inspect(other)}"]
      end
    end)
  end

  defp validate_section("engine", engines) when map_size(engines) == 0, do: []

  defp validate_section("engine", engines) do
    Enum.flat_map(engines, fn {name, spec} -> validate_engine(name, spec) end)
  end

  defp validate_section("provider", providers) do
    Enum.flat_map(providers, fn {name, spec} -> validate_provider(name, spec) end)
  end

  defp validate_section("model", models) do
    Enum.flat_map(models, fn {name, spec} -> validate_model(name, spec) end)
  end

  defp validate_section("consumer", consumers) do
    Enum.flat_map(consumers, fn
      {name, spec} when is_map(spec) -> validate_consumer(name, spec)
      {name, other} -> ["consumer '#{name}' must be a table, got: #{inspect(other)}"]
    end)
  end

  defp validate_section("general", general) when is_map(general), do: validate_general(general)
  defp validate_section(section, _), do: ["#{section} must be a table"]

  defp validate_general(general) do
    for key <- ~w(data_dir log_dir default_consumer),
        Map.has_key?(general, key),
        not is_binary(general[key]) do
      "general.#{key} must be a string, got: #{inspect(general[key])}"
    end
  end

  defp validate_engine(name, spec) when is_map(spec) do
    validate_binary(name, spec) ++
      validate_install(name, spec) ++
      validate_auth(name, spec)
  end

  defp validate_engine(name, spec),
    do: ["engine '#{name}' must be a table, got: #{inspect(spec)}"]

  defp validate_binary(name, spec) do
    case Map.get(spec, "binary") do
      nil -> []
      value when is_binary(value) -> []
      other -> ["engine '#{name}'.binary must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_install(name, spec) do
    case Map.get(spec, "install") do
      nil -> []
      install when is_map(install) -> validate_install_table(name, install)
      other -> ["engine '#{name}'.install must be a table, got: #{inspect(other)}"]
    end
  end

  defp validate_install_table(name, install) do
    strategy = Map.get(install, "strategy")

    problems =
      case strategy do
        "precompiled" ->
          validate_precompiled(name, install)

        "source" ->
          validate_source_install(name, install)

        "none" ->
          []

        nil ->
          ["engine '#{name}'.install.strategy is required"]

        other ->
          [
            "engine '#{name}'.install.strategy must be precompiled, source or none, got: #{inspect(other)}"
          ]
      end

    problems ++ validate_cmake_args(name, install)
  end

  defp validate_precompiled(name, install) do
    case Map.get(install, "dir") do
      nil -> ["engine '#{name}'.install.dir is required for strategy precompiled"]
      value when is_binary(value) -> []
      other -> ["engine '#{name}'.install.dir must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_source_install(name, install) do
    Enum.flat_map(~w(repo dir binaries), &validate_source_install_key(name, install, &1))
  end

  defp validate_source_install_key(name, install, "binaries") do
    case Map.get(install, "binaries") do
      nil ->
        ["engine '#{name}'.install.binaries is required for strategy source"]

      [] ->
        # An empty list would build successfully and install nothing, so it is
        # a missing field rather than an empty one.
        ["engine '#{name}'.install.binaries must not be empty"]

      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1),
          do: [],
          else: [
            "engine '#{name}'.install.binaries must be a list of strings, got: #{inspect(value)}"
          ]

      other ->
        ["engine '#{name}'.install.binaries must be a list of strings, got: #{inspect(other)}"]
    end
  end

  defp validate_source_install_key(name, install, key) do
    case Map.get(install, key) do
      nil -> ["engine '#{name}'.install.#{key} is required for strategy source"]
      value when is_binary(value) -> []
      other -> ["engine '#{name}'.install.#{key} must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_cmake_args(name, install) do
    case Map.get(install, "cmake_args") do
      nil ->
        []

      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1),
          do: [],
          else: ["engine '#{name}'.install.cmake_args must be a list of strings"]

      other ->
        ["engine '#{name}'.install.cmake_args must be a list, got: #{inspect(other)}"]
    end
  end

  defp validate_auth(name, spec) do
    case Map.get(spec, "auth") do
      nil -> []
      auth when is_map(auth) -> validate_auth_table(name, auth)
      other -> ["engine '#{name}'.auth must be a table, got: #{inspect(other)}"]
    end
  end

  defp validate_auth_table(name, auth) do
    Enum.flat_map(~w(api_key api_key_env), fn key ->
      case Map.get(auth, key) do
        nil -> []
        value when is_binary(value) -> []
        other -> ["engine '#{name}'.auth.#{key} must be a string, got: #{inspect(other)}"]
      end
    end)
  end

  defp validate_model(name, spec) when is_map(spec) do
    validate_model_type(name, spec) ++
      validate_model_port(name, spec) ++
      validate_model_args(name, spec) ++
      validate_model_source(name, spec) ++
      validate_model_usage(name, spec)
  end

  defp validate_model(name, spec), do: ["model '#{name}' must be a table, got: #{inspect(spec)}"]

  defp validate_model_type(name, spec) do
    case Map.get(spec, "type") do
      nil -> ["model '#{name}'.type is required"]
      type when type in ~w(local remote external) -> []
      other -> ["model '#{name}'.type must be local, remote or external, got: #{inspect(other)}"]
    end
  end

  # A list, not a map, and the reason is llama-server: it takes the last
  # occurrence of a repeated flag, so `--cpu` has to be able to come after the
  # model's own `--n-gpu-layers`. A TOML map has no order to lose.
  defp validate_model_args(name, spec) do
    case Map.get(spec, "model_args") do
      nil ->
        []

      args when is_map(args) ->
        [
          "model '#{name}'.model_args must be an ordered list, not a table. " <>
            "llama-server takes the last occurrence of a repeated flag, so the order is behaviour."
        ]

      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1),
          do: [],
          else: ["model '#{name}'.model_args must be a list of strings"]

      other ->
        ["model '#{name}'.model_args must be a list, got: #{inspect(other)}"]
    end
  end

  defp validate_model_port(name, spec) do
    case Map.get(spec, "port") do
      nil -> []
      "auto" -> []
      port when is_integer(port) and port > 0 and port < 65_536 -> []
      other -> ["model '#{name}'.port must be \"auto\" or an integer, got: #{inspect(other)}"]
    end
  end

  defp validate_model_source(name, spec) do
    case Map.get(spec, "source") do
      nil -> []
      source when is_map(source) -> validate_source_table(name, source)
      other -> ["model '#{name}'.source must be a table, got: #{inspect(other)}"]
    end
  end

  defp validate_source_table(name, source) do
    case Map.get(source, "kind") do
      nil ->
        ["model '#{name}'.source.kind is required"]

      "huggingface" ->
        validate_hf_source(name, source)

      "url" ->
        validate_url_source(name, source)

      "local" ->
        validate_local_source(name, source)

      other ->
        ["model '#{name}'.source.kind must be huggingface, url or local, got: #{inspect(other)}"]
    end
  end

  defp validate_hf_source(name, source) do
    Enum.flat_map(~w(repo file), fn key ->
      case Map.get(source, key) do
        nil -> ["model '#{name}'.source.#{key} is required for kind huggingface"]
        value when is_binary(value) -> []
        other -> ["model '#{name}'.source.#{key} must be a string, got: #{inspect(other)}"]
      end
    end)
  end

  defp validate_url_source(name, source) do
    case Map.get(source, "url") do
      nil -> ["model '#{name}'.source.url is required for kind url"]
      _ when is_map(source) -> []
      other -> ["model '#{name}'.source.url must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_local_source(name, source) do
    case Map.get(source, "path") do
      nil -> ["model '#{name}'.source.path is required for kind local"]
      value when is_binary(value) -> []
      other -> ["model '#{name}'.source.path must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_model_usage(name, spec) do
    case Map.get(spec, "usage") do
      nil ->
        []

      usage when is_list(usage) ->
        if Enum.all?(usage, &is_binary/1),
          do: [],
          else: ["model '#{name}'.usage must be a list of strings"]

      other ->
        ["model '#{name}'.usage must be a list, got: #{inspect(other)}"]
    end
  end

  defp validate_provider(name, spec) when is_map(spec) do
    # Both problems are reported even when the type is missing: a provider
    # table with no type and no base_url has two faults, and fixing them one
    # run at a time is slower than reading both.
    validate_provider_type(name, spec) ++
      validate_provider_url(name, spec) ++
      validate_provider_key(name, spec)
  end

  defp validate_provider(name, spec),
    do: ["provider '#{name}' must be a table, got: #{inspect(spec)}"]

  defp validate_provider_type(name, spec) do
    case Map.get(spec, "type") do
      nil -> ["provider '#{name}'.type is required"]
      value when is_binary(value) -> []
      other -> ["provider '#{name}'.type must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_provider_url(name, spec) do
    case Map.get(spec, "base_url") do
      nil -> ["provider '#{name}'.base_url is required"]
      value when is_binary(value) -> []
      other -> ["provider '#{name}'.base_url must be a string, got: #{inspect(other)}"]
    end
  end

  defp validate_provider_key(name, spec) do
    case Map.get(spec, "api_key") do
      nil ->
        []

      key when is_map(key) ->
        if Map.has_key?(key, "env"),
          do: [],
          else: ["provider '#{name}'.api_key must be a string or {env = \"VAR\"}"]

      key when is_binary(key) ->
        []

      other ->
        ["provider '#{name}'.api_key must be a string or {env = \"VAR\"}, got: #{inspect(other)}"]
    end
  end

  defp validate_consumer(name, spec) do
    case Map.get(spec, "model_default") do
      nil -> ["consumer '#{name}'.model_default is required"]
      value when is_atom(value) or is_binary(value) -> []
      other -> ["consumer '#{name}'.model_default must be an alias, got: #{inspect(other)}"]
    end
  end
end
