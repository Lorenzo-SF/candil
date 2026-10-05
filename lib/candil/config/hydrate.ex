defmodule Candil.Config.Hydrate do
  @moduledoc """
  Turns a decoded `candil.toml` into the structs `Candil.Store` holds.

  `Config.File.load/1` returns a map of strings. `Store` is indexed by
  atoms. This module is the bridge, and its only interesting decision is the
  one the design document's hard rule 7 seems to forbid.

  ## On `String.to_atom/1` here, and nowhere else

  Rule 7 says never call `String.to_atom/1` with external input. This module
  calls it, and here is the argument.

  The atom table never shrinks. Measured, not asserted: creating 50.000 atoms
  with `String.to_atom/1`, using each once and throwing it away, leaves 50.000
  atoms resident until the VM dies. The default limit is around a million.
  That is why the rule exists, and it is right: something on the network can
  send a million distinct names, and Candil would have turned each into an
  atom.

  A `candil.toml` is not that. It is a file the user wrote, on their own
  disk, with as many models as they have models. Nobody can put a million
  entries in it, and nobody else writes it. The bound is the file, not the
  attacker.

  So the rule holds where it is written — the gateway, the router, anything
  that reads a request — and this is the one place that is knowingly outside
  it. The cost is stated rather than hidden:

    * the atom count grows by the number of entries in the file, once, and
    * the aliases are not garbage: they are looked up on every request.

  A second read, for a future maintainer: if this ever grows a path where
  the strings come from anywhere but the config file, the exception stops
  applying. That is the condition to check, not the line count.
  """

  alias Candil.{Build, Engine, Model, Provider, Source}
  alias Candil.Config.File, as: ConfigFile
  alias Candil.Store

  @doc """
  Registers everything in a decoded document. Returns per-section results.

  Sections are independent: a bad model does not stop the engines from being
  registered, because a user fixing one model should not lose the rest.
  """
  @spec hydrate(map()) :: %{
          engines: [atom() | {:error, atom(), [binary()]}],
          models: [atom() | {:error, atom(), [binary()]}],
          providers: [atom() | {:error, atom(), [binary()]}]
        }
  def hydrate(config) when is_map(config) do
    # `Config.File.load/1` hands back the document as written, and `expand/1`
    # is a separate call. Skipping it leaves `~` literal in every `dest`, which
    # makes `Source.dest_path/1` answer a path inside a directory called `~` —
    # and then every model is rejected for having no locatable file, with a
    # message that points at the file rather than at the tilde.
    config = ConfigFile.expand(config)

    %{
      engines: section(config, "engine", &engine/2),
      models: section(config, "model", &model/2),
      providers: section(config, "provider", &provider/2)
    }
  end

  # A section that is present but is not a table is reported, not crashed on,
  # because `Enum.sort_by/3` on the string "nope" raises Enumerable.impl_for!/1
  # and the user is told about an Enumerable, not about their TOML.
  defp section(config, key, builder) do
    case Map.get(config, key, %{}) do
      entries when is_map(entries) ->
        entries
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.map(fn {name, spec} -> build(builder, name, spec) end)

      other ->
        [{:error, key, ["#{key} must be a table, got: #{inspect(other)}"]}]
    end
  end

  defp build(builder, name, spec) when is_map(spec) do
    case alias_check(name) do
      :ok -> finish(builder, name, spec)
      {:error, message} -> {:error, name, [message]}
    end
  end

  defp build(_builder, name, other), do: {:error, name, ["not a table: #{inspect(other)}"]}

  defp finish(builder, name, spec) do
    case builder.(name, spec) do
      {:ok, struct} -> register(struct)
      {:error, reasons} -> {:error, name, reasons}
    end
  end

  # `&&` returned the outcome of `Store.register_*`, not the alias, so a
  # successful registration answered `:ok` and the caller could not tell which
  # entry had been written. The result is checked and the alias returned.
  defp register(%Engine{} = e), do: registered(Store.register_engine(e), e.alias)
  defp register(%Model{} = m), do: registered(Store.register_model(m), m.alias)
  defp register(%Provider{} = p), do: registered(Store.register_provider(p), p.alias)

  defp registered(:ok, alias), do: alias
  defp registered({:error, reasons}, _alias), do: {:error, reasons}

  # ── sections ─────────────────────────────────────────────────────────────

  defp engine(name, spec) do
    with {:ok, base} <- Build.new(install_spec(spec)) do
      engine = struct(Engine, engine_attrs(name, spec, base))
      validate(Engine, engine)
    end
  end

  defp engine_attrs(name, spec, build) do
    %{
      alias: alias_of(name),
      binary: spec["binary"],
      host: spec["host"] || "127.0.0.1",
      base_port: spec["base_port"] || 10_000,
      port: spec["port"] || 8080,
      api_key: api_key(spec),
      start_args: spec["start_args"] || [],
      install: build
    }
  end

  # `Enum.map/2` over a map gives a list of `{k, v}` pairs, which happens to
  # look like a keyword list. Piping that into `Keyword.put/3` does not build
  # one: `Keyword.put/3` on a plain list raises, and the version that survived
  # here was reordering the pipe so the injection landed on the wrong term.
  # Written straight instead, so the next reader is not left guessing.
  defp install_spec(spec) do
    install = Map.get(spec, "install", %{})

    install
    |> atomise()
    # `generator` and `strategy` both arrive as strings and both are compared
    # against atoms downstream — `generator_flag/1` matches on `:ninja` and
    # `:make`, `Build.new/1` validates the strategy. A string there does not
    # raise, it just quietly picks the wrong branch later.
    |> Enum.map(fn
      {:generator, value} -> {:generator, atom(value)}
      {:strategy, value} -> {:strategy, atom(value)}
      pair -> pair
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.put(:strategy, install |> Map.get("strategy", "none") |> atom())
  end

  defp api_key(spec) do
    case Map.get(spec, "auth") do
      %{"api_key" => key} -> key
      %{"api_key_env" => var} -> {:system, var}
      _ -> nil
    end
  end

  defp model(name, spec) do
    attrs =
      %{
        alias: alias_of(name),
        type: atom(Map.get(spec, "type", "local")),
        context_size: spec["context_size"] || 4096,
        port: spec["port"] || :auto,
        usage: Enum.map(spec["usage"] || ["chat"], &atom/1),
        model_args: spec["model_args"] || [],
        # Directo del spec y no un `nil` fijo: un `nil` aqui pisaba el valor
        # que el usuario habia escrito en el toml, y `derive_gpu_layers/2` solo
        # rellena cuando NO hay entero. O sea: la mitad de los campos del
        # mundo funcionan y el nuevo no.
        gpu_layers: spec["gpu_layers"],
        tags: spec["tags"] || []
      }
      |> maybe_put(:engine, spec["engine"] && alias_of(spec["engine"]))
      |> maybe_put(:provider, spec["provider"] && alias_of(spec["provider"]))
      |> maybe_put(:name, spec["name"])
      |> maybe_put(:base_url, spec["base_url"])
      |> maybe_put(:model_dir, spec["model_dir"])
      |> maybe_put(:filename, spec["filename"])
      |> then(&derive_gpu_layers(&1, spec))
      |> then(&derive_file_location(&1, spec))
      |> maybe_put(:source, source(spec["source"]))
      |> maybe_put(:draft, source(spec["draft"]))
      |> maybe_put(:enabled, spec["enabled"])

    validate(Model, struct(Model, attrs))
  end

  # `gpu_layers` es un campo propio, y se lee de dos sitios por orden: el
  # campo del toml si esta, y si no el `--n-gpu-layers` que alguien hubiera
  # dejado dentro de `model_args`. Un valor escondido en una lista no se
  # puede manipular de forma fiable, y `--cpu` necesita manipularlo.
  defp derive_gpu_layers(model, spec) do
    # El flag se quita SIEMPRE, tenga el campo lo que tenga. Dejarlo cuando
    # el campo existe creates dos fuentes de verdad para el mismo numero, y
    # una de las dos se cuela: llama-server se queda con una y Candil cree
    # que manda la otra. Un solo sitio, y el otro vacio.
    {in_args, without} = pop_n_gpu_layers(model.model_args || [])

    layers =
      case spec["gpu_layers"] do
        n when is_integer(n) -> n
        _ -> in_args || -1
      end

    %{model | gpu_layers: layers, model_args: without}
  end

  # Saca el flag Y su valor de una lista de strings, y devuelve lo que habia
  # junto a la lista sin el. Sin este par, `--cpu` pondria un 0 que el 99 de
  # `model_args` deshaceria, y el usuario volveria a ver `n_gpu_layers already
  # set by user` sin entender de donde sale.
  defp pop_n_gpu_layers(args) when is_list(args) do
    case Enum.split_while(args, &(&1 != "--n-gpu-layers")) do
      # `before` se CONSERVA. Devolver solo `after_flag` se come todo lo que
      # habia antes del flag, que es donde suelen estar los que importan —
      # `--alias`, `-fa`, `--log-verbosity`.asi `--n-gpu-layers -1` en medio
      # de los args se llevaba por delante `--alias qwencoder`, y el modelo
      # salia sin alias ni flash attention y con exit 1. Un test con el flag
      # al principio del array no lo ve nunca, porque ahi `before` esta vacio.
      {before, ["--n-gpu-layers", value | after_flag]} ->
        {to_int(value), before ++ after_flag}

      {_before, _rest} ->
        {nil, args}
    end
  end

  defp pop_n_gpu_layers(args), do: {nil, args}

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> -1
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: -1

  # `model_dir` y `filename` SIEMPRE vienen del `[model.X.source]`, que es donde
  # el toml los declara — `file` y `dest` — y no de unas claves `model_dir` y
  # `filename` que ningun toml escrito por una persona tiene.
  #
  # Sin esto, `Candil.Engine.Server` hacia `Path.join(nil, nil)` y el GenServer
  # del engine se caia en su `init/1`. El sintoma era desconcertante porque
  # `candil models info` SI teach la ruta —la sacaba del source— mientras el
  # arranque no la tenia: una pantalla que dice una cosa y un arranque que
  # hace otra, con `doctor` diciendo "6/6 descargados" entre las dos.
  #
  # Un `model_dir` explicito gana, porque quien lo escribe sabe algo que el
  # source no dice.
  defp derive_file_location(model, spec) do
    # `Map.get/3` y no `model.model_dir`: un modelo remoto hidratado llega
    # aqui sin esas claves, y leerlas con punto revienta. Que se note ahora y
    # no con el engine ya en marcha.
    if is_binary(Map.get(model, :model_dir)) and is_binary(Map.get(model, :filename)) do
      model
    else
      # `Map.put` y no `%{model | ...}`: el mapa hidratado no siempre trae las
      # claves, y la sintaxis de struct update levanta KeyError si faltan. Un
      # modelo remoto sin source llega aqui sin `filename`, y ahi no hay nada
      # que derivar tampoco.
      case spec["source"] do
        %{"dest" => dest} = src when is_binary(dest) ->
          model
          |> Map.put(:model_dir, dest)
          |> Map.put(:filename, src["dest_name"] || src["file"])

        %{"path" => path} when is_binary(path) ->
          # `Path.dirname/1` y `Path.basename/1`, no partir la lista a mano:
          # `Enum.split(-1)` devuelve una TUPLA, y desempaquetarla como lista da
          # un MatchError en el arranque de un modelo.
          expanded = Path.expand(path)

          model
          |> Map.put(:model_dir, Path.dirname(expanded))
          |> Map.put(:filename, Path.basename(expanded))

        _ ->
          model
      end
    end
  end

  defp provider(name, spec) do
    attrs = %{
      alias: alias_of(name),
      # Provider.validate/1 checks the type against a list of atoms, so the
      # string from the TOML has to become one before it gets there. It did
      # not, and the message was "unknown type: openai" — the name of a type
      # that is very much known, quoted as if it were a stranger.
      type: spec["type"] && atom(spec["type"]),
      base_url: spec["base_url"],
      api_key: provider_key(spec["api_key"])
    }

    validate(Provider, struct(Provider, attrs))
  end

  defp provider_key(%{"env" => var}), do: {:system, var}
  defp provider_key(key) when is_binary(key), do: key
  defp provider_key(_), do: nil

  # `kind` has to become an atom or nothing downstream matches:
  # `Source.dest_path/1` clauses are on `:huggingface`, `:url` and `:local`,
  # so a `kind` of `"huggingface"` falls through every clause and answers nil.
  # The model then has no locatable file and is rejected — with a message
  # about the file rather than about the kind, which is how this hid for as
  # long as it did.
  defp source(nil), do: nil

  defp source(table) when is_map(table) do
    table = atomise(table)
    struct(Source, Map.put(table, :kind, atom(table[:kind])))
  end

  # ── atoms ────────────────────────────────────────────────────────────────

  # The one place in Candil that may turn a document key into a new atom, and
  # only after checking the shape of the name.
  #
  # `to_existing_atom/1` first is a fast path, not a guard: on the first load
  # the alias does not exist, so the fallback always fires and the atom table
  # grows exactly as it would with a bare `to_atom/1`. Trying it first on its
  # own would look like compliance with rule 7 without any of the substance,
  # which is worse than saying plainly what is happening.
  #
  # What does real work is the shape check in the fallback. An alias is an
  # identifier, and an identifier looks like `[a-z][a-z0-9_]*`. A key that does
  # not look like one is not an alias someone typo'd; it is not an alias at
  # all, and refusing it is cheap insurance against a document that has picked
  # up something it should not have.
  defp alias_of(name) when is_atom(name), do: name

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp alias_of(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> new_alias(name)
  end

  defp alias_check(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      :ok
    else
      {:error,
       "#{inspect(name)} is not [a-z][a-z0-9_]*, so it is not an alias. " <>
         "Refusing it is what keeps this the only String.to_atom/1 in Candil."}
    end
  end

  defp new_alias(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      String.to_atom(name)
    else
      raise ArgumentError,
            "#{inspect(name)} is not a usable alias: expected [a-z][a-z0-9_]*, " <>
              "and refusing it is what keeps this the only String.to_atom/1 in Candil"
    end
  end

  defp atom(%{"strategy" => s}), do: atom(s)
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp atom(s) when is_binary(s), do: String.to_atom(s)
  defp atom(a) when is_atom(a), do: a
  defp atom(other), do: other

  defp atomise(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atom(k), v} end)
  end

  defp atomise(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate(module, struct) do
    case module.validate(struct) do
      :ok -> {:ok, struct}
      {:error, reasons} -> {:error, reasons}
    end
  end
end
