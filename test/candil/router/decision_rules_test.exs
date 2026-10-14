defmodule Candil.Router.DecisionRulesTest do
  @moduledoc """
  Reglas declarativas que **cambian el veredicto**, y la linea que las separa de ser
  un diccionario de palabras.

  Lo importante no es que la regla aplique: es que un **veto no se pueda
  deshacer**. Es la regla de D-09 —*«ninguna puede devolver un modelo
  vetado»*— puesta en el sitio donde se puede comprobar: un `prefer` de diez
  puntos no resucita a un vetado, ni en la misma regla ni en otra posterior.
  """

  use ExUnit.Case, async: false

  alias Candil.Router
  alias Candil.Router.{Decision, DecisionRules}

  defp decision(model, strategy \\ :default) do
    %Decision{
      model_alias: model,
      strategy: strategy,
      score: 0.5,
      reason: "no layer cleared its threshold",
      alternatives: [],
      degraded: [],
      confidence: :full,
      timestamp: DateTime.utc_now()
    }
  end

  defp con_reglas(toml) do
    tmp = Path.join(System.tmp_dir!(), "candil-dec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "candil.toml"), toml)
    System.put_env("CANDIL_CONFIG", Path.join(tmp, "candil.toml"))

    on_exit(fn ->
      System.delete_env("CANDIL_CONFIG")
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "leer el toml" do
    test "una entrada sin accion NO es una regla" do
      # Sin accion no hace nada, y devolverla haria creer al motor que si.
      assert DecisionRules.from_config(%{decisions: [%{reason: "hola", when: %{}}]}) == []
    end

    test "se ordenan por prioridad, de mayor a menor" do
      reglas =
        DecisionRules.from_config(%{
          decisions: [
            %{priority: 10, force: "a"},
            %{priority: 100, force: "b"},
            %{priority: 50, force: "c"}
          ]
        })

      assert Enum.map(reglas, & &1.force) == ["b", "c", "a"]
    end

    test "el toml de verdad llega" do
      con_reglas("""
      [[router.decision]]
      reason = "el posadero solo indexa"
      when = { consumer = "posadero" }
      force = "embed"
      """)

      reglas = DecisionRules.from_config(Router.settings())

      assert [regla] = reglas
      assert regla.force == "embed"
      assert regla.when == %{consumer: "posadero"}
    end
  end

  describe "las tres acciones" do
    test "force elige otro modelo y lo dice" do
      reglas = [%{reason: "a mano", priority: 1, when: %{}, force: "otro", prefer: nil, veto: []}]

      {:ok, d} = DecisionRules.apply(reglas, decision(:original), :default, [:original, :otro])

      assert d.model_alias == :otro
      assert d.reason =~ "a mano"
    end

    test "prefer NO puede deshacer un veto" do
      reglas = [
        %{
          reason: "veto duro",
          priority: 100,
          when: %{},
          force: nil,
          prefer: nil,
          veto: [:prohibido]
        },
        %{
          reason: "prefiero ese mismo",
          priority: 10,
          when: %{},
          force: nil,
          prefer: {"prohibido", 10.0},
          veto: []
        }
      ]

      {:ok, d} = DecisionRules.apply(reglas, decision(:prohibido), :default, [:prohibido, :otro])

      # El veto manda. Un `prefer` de diez puntos no resucita a un vetado: es
      # la regla de D-09 puesta en el sitio donde se puede comprobar.
      assert d.model_alias == :otro
      assert d.degraded != []
    end

    test "veto quita el modelo aunque una regla anterior lo forzara" do
      reglas = [
        %{reason: "fuerzo", priority: 100, when: %{}, force: "prohibido", prefer: nil, veto: []},
        %{
          reason: "y lo veto",
          priority: 1,
          when: %{},
          force: nil,
          prefer: nil,
          veto: ["prohibido"]
        }
      ]

      {:ok, d} = DecisionRules.apply(reglas, decision(:otro), :default, [:prohibido, :otro])

      assert d.model_alias == :otro
    end

    test "un force a un modelo que no esta NO se aplica, y no inventa destino" do
      reglas = [
        %{
          reason: "a uno inexistente",
          priority: 1,
          when: %{},
          force: "fantasma",
          prefer: nil,
          veto: []
        }
      ]

      {:ok, d} = DecisionRules.apply(reglas, decision(:original), :default, [:original])

      # Forzar algo que no existe no es forzar: es mentir. Se aplica lo que
      # hubiera ganado y se dice.
      assert d.model_alias == :original
    end

    test "un prefer a un modelo ausente no puntua a un fantasma" do
      reglas = [
        %{
          reason: "prefiere a nadie",
          priority: 1,
          when: %{},
          force: nil,
          prefer: {"fantasma", 5.0},
          veto: []
        }
      ]

      {:ok, d} = DecisionRules.apply(reglas, decision(:original), :default, [:original])

      assert d.model_alias == :original
      refute d.reason =~ "fantasma"
    end
  end

  describe "TODOS vetados" do
    test "es un ERROR explicito, no una decision que devuelve un vetado" do
      # La regla de D-09 —*«ninguna politica puede devolver un modelo vetado»*—
      # es BINARIA: o hay un superviviente o no hay decision. Antes aqui se
      # devolvia la decision tal cual apuntando al vetado, y solo porque nadie
      # habia vetado los tres candidatos a la vez nadie lo habia visto.
      reglas = [
        %{
          reason: "veto total",
          priority: 1,
          when: %{},
          force: nil,
          prefer: nil,
          veto: ["uno", "dos", "tres"]
        }
      ]

      assert DecisionRules.apply(reglas, decision(:uno), :default, [:uno, :dos, :tres]) ==
               {:error, :all_candidates_vetoed}
    end

    test "y si solo queda uno sin vetar, ese gana" do
      reglas = [
        %{
          reason: "veto a dos",
          priority: 1,
          when: %{},
          force: nil,
          prefer: nil,
          veto: ["uno", "dos"]
        }
      ]

      assert {:ok, d} = DecisionRules.apply(reglas, decision(:uno), :default, [:uno, :dos, :tres])
      assert d.model_alias == :tres
    end
  end

  describe "las condiciones" do
    test "solo aplican las que casan" do
      reglas = [
        %{
          reason: "es otro consumer",
          priority: 10,
          when: %{consumer: "posadero"},
          force: "embed",
          prefer: nil,
          veto: []
        },
        %{
          reason: "es este consumer",
          priority: 10,
          when: %{consumer: "default"},
          force: "nuevo",
          prefer: nil,
          veto: []
        }
      ]

      {:ok, d} =
        DecisionRules.apply(reglas, decision(:original), :default, [:original, :nuevo, :embed])

      assert d.model_alias == :nuevo
    end

    test "una condicion que no se cumple no hace nada, en silencio y sin error" do
      reglas = [
        %{
          reason: "solo si es llm",
          priority: 1,
          when: %{strategy: "llm"},
          force: "nuevo",
          prefer: nil,
          veto: []
        }
      ]

      {:ok, d} =
        DecisionRules.apply(reglas, decision(:original, :default), :default, [:original, :nuevo])

      assert d.model_alias == :original
    end

    test "sin reglas, la decision se queda igual" do
      {:ok, d} = DecisionRules.apply([], decision(:original), :default, [:original])

      assert d.model_alias == :original
      assert d.reason == "no layer cleared its threshold"
    end
  end
end
