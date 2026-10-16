defmodule Candil.Router.RulesFromConfigTest do
  @moduledoc """
  `[router.rules]` de verdad, y no de palabra.

  ## Que estaba roto

  `config/template.ex` decia —y sigue diciendo, ahora con razon— que
  *«las reglas de palabras van aparte, en `[router.rules]`»*. Y **nadie lo
  leia**: `grep "router.rules" lib/` daba cero. La capa vivia en un `@rules` de
  modulo, en ingles, con las categorias mapeadas a tres alias fijos.

  Eso tiene dos consecuencias que no son academicas:

  1. **La capa no se puede tocar sin recompilar.** Y el proyecto entero esta
     escrito para que se touch sin recompilar.
  2. **Para quien escribe en otro idioma es inalcanzable.** Las palabras estan
     en ingles; un prompt en espanol no casa, y el propio codigo lo dice:
     *«a near-miss across languages does not match, and pretending otherwise
     would make the score a lie»*.

     Medido sobre 84 peticiones reales de siete repos, en espanol: la capa
     disparo **cero veces**.

  ## Que se prueba aqui

  Que la tabla se lee, que gana la que tiene mas palabras, y que **sin
  `[router.rules]` no cambia nada** — que es lo que no se puede romper.
  """

  use ExUnit.Case, async: false

  alias Candil.Router
  alias Candil.Router.Scorer

  @nada [%{role: "user", content: "hola"}]

  defp con_reglas(toml) do
    tmp = Path.join(System.tmp_dir!(), "candil-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "candil.toml"), toml)

    Candil.TestConfig.override!(Path.join(tmp, "candil.toml"))

    on_exit(fn -> File.rm_rf(tmp) end)

    :ok
  end

  defp reglas_del_toml, do: Map.get(Router.settings(), :rules)

  # El camino REAL: es `score/4` quien convierte los alias de string a atomo.
  # `rule_score/3` ya recibe el mapa convertido, y probarlo con el crudo
  # midiria una capa que no existe.
  defp con_capa(mensajes, candidatos) do
    Scorer.score(mensajes, candidatos, :rule, Router.settings())
  end

  describe "lo que el toml dice" do
    test "[router.rules] se lee, indexado por alias" do
      con_reglas("""
      [router.rules.coder]
      words = ["arregla", "compila"]

      [router.rules.verificador]
      words = ["analiza", "demuestra"]
      """)

      reglas = reglas_del_toml()

      # Del toml sale con claves STRING: `[router.rules.coder]` es
      # `%{"coder" => %{"words" => [...]}}`. La conversion a atomo la hace
      # `Scorer` al puntuar, que es donde los alias tienen que ser los del Store.
      assert reglas["coder"] == %{"words" => ["arregla", "compila"]}
      assert reglas["verificador"] == %{"words" => ["analiza", "demuestra"]}
    end

    test "y si no esta, no hay reglas: la capa queda inerte" do
      con_reglas("[router]\n")

      assert reglas_del_toml() == nil
    end
  end

  describe "la capa, con reglas del toml" do
    setup do
      con_reglas("""
      [router.rules.coder]
      words = ["arregla", "bug", "compila"]

      [router.rules.verificador]
      words = ["analiza", "compara", "demuestra"]
      """)

      :ok
    end

    test "una palabra en espanol ya mueve la aguja" do
      # Con el `@rules` de modulo esto NO dispara: no hay «arregla» en ingles.
      # Con `[router.rules]` escrito en el idioma de quien programa, si.
      codigo = [%{role: "user", content: "arregla el bug"}]

      refute con_capa(codigo, [:coder]) == :miss
    end

    test "y decide por el que mas palabras casa" do
      # La peticion es de codigo: dos palabras suyas y ninguna del otro.
      codigo = [%{role: "user", content: "arregla el bug y compila"}]

      assert {:ok, [{:coder, _}], _why} = con_capa(codigo, [:coder, :verificador])
    end

    test "la capa devuelve :miss si no hay reglas en el toml" do
      con_reglas("[router]\n")
      # Sin `[router.rules]` se usa la vocabulary de reserva, que es ingles; un
      # prompt en espanol no casa y la capa se salta sola, sin error.
      assert Scorer.score(@nada, [:coder], :rule, Router.settings()) == :miss
    end
  end

  describe "sin tocar nada" do
    test "sin [router.rules] el comportamiento es el de antes" do
      con_reglas("[router]\n")

      # El `@rules` de modulo, en ingles: sigue clasifica las peticiones de
      # antes y **no se ha movido un solo test**.
      codigo = [%{role: "user", content: "refactor this function, there is a bug"}]

      assert Scorer.rule_score(codigo, :coder) > 0.0
    end
  end
end
