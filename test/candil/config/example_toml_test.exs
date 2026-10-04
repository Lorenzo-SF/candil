defmodule Candil.Config.ExampleTomlTest do
  @moduledoc """
  The example config has to parse. It is the first thing anyone is told to try,
  and it is what a new session points at — so a broken one sends the next
  person to `no models configured` with no clue why, and the person who typed
  the file never learns that a repo artefact was already broken.
  """
  use ExUnit.Case, async: true

  @example Path.join([File.cwd!(), "proyecto 4.0", "candil.toml"])

  test "it exists" do
    assert File.exists?(@example), "el ejemplo no esta en #{@example}"
  end

  test "it parses and declares something to look at" do
    case Candil.Config.File.load(@example) do
      {:ok, config} ->
        models = Map.get(config, "model", %{})
        assert map_size(models) > 0, "el ejemplo no declara ningun modelo"

        # Not a count: an alias. `candil models info <alias>` is what the
        # manual test doc tells someone to type, and it has to name something
        # that exists.
        assert Enum.all?(Map.keys(models), &is_binary/1),
               "las claves de [model.*] deberian ser el alias en texto"

      {:error, reason} ->
        # The whole point: the failure is reported here, in the suite, rather
        # than by the first person to `export CANDIL_CONFIG=...`.
        flunk("el ejemplo no parsea: #{inspect(reason)}")
    end
  end

  test "it has at least one model a manual check can start" do
    {:ok, config} = Candil.Config.File.load(@example)

    # Something pullable and local. A remote model in the example is fine as
    # long as it is not the *only* one, or the manual test can never run.
    local =
      config
      |> Map.get("model", %{})
      |> Enum.filter(fn {_alias, model} -> to_string(model["type"]) == "local" end)

    assert local != [], "el ejemplo no declara ningun modelo local que se pueda arrancar"
  end
end
