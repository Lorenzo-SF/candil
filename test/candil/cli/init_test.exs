defmodule Candil.CLI.InitTest do
  @moduledoc """
  `candil init` y la plantilla que escribe.

  La plantilla se prueba contra el parser de verdad, no con una regexp: una
  plantilla que Candil no puede leer es peor que no tenerla, porque el
  usuario la descomenta, la edita y pierde la sesion entera por un error de
  sintaxis que podia haberse detectado aqui.
  """
  use ExUnit.Case, async: false

  alias Candil.CLI.Init
  # `Candil.Config.File` como `File` tapa a `Elixir.File`, y entonces
  # `File.mkdir_p!/1` es una funcion que no existe.
  alias Candil.Config.File, as: ConfigFile
  alias Candil.Config.Template

  @tmp Path.join(System.tmp_dir!(), "candil-init-test-#{System.unique_integer([:positive])}")

  setup do
    on_exit(fn ->
      File.rm_rf(@tmp)
      File.rm_rf(Path.join(@tmp, ".config/candil/candil.toml"))
    end)

    :ok
  end

  describe "la plantilla" do
    test "el texto que se escribe parsea con el parser de Candil" do
      path = Path.join(@tmp, "plantilla.toml")
      File.mkdir_p!(@tmp)
      assert :ok == File.write(path, template())

      # Sin esto, la prueba de "escribe un fichero" y la de "escribe algo
      # utilizable" serian la misma, y soloARIAN estar la segunda.
      assert {:ok, config} = ConfigFile.load(path)
      assert config == %{}
    end

    test "menciona cada seccion configurable del schema" do
      text = template()

      for section <- ~w(general engine model provider) do
        assert text =~ "[#{section}", "la plantilla no documenta [#{section}]"
      end
    end

    test "avisa de que un flag y su valor son dos elementos, que es el error que se repite" do
      # El bug real: "--n-gpu-layers -1" en un elemento. Se documento aqui
      # porque es el error que se ha-commitado dos veces.
      assert template() =~ "son DOS elementos"
    end
  end

  describe "run/1" do
    test "escribe la plantilla en la ruta indicada" do
      path = Path.join(@tmp, "nuevo.toml")
      assert :ok == Init.run(%{path: path, force: false})
      assert File.read!(path) == template()
    end

    test "no pisa una configuracion existente" do
      path = Path.join(@tmp, "mio.toml")
      File.mkdir_p!(@tmp)
      File.write!(path, "# lo que escribi yo\n")

      assert :ok == Init.run(%{path: path, force: false})
      assert File.read!(path) == "# lo que escribi yo\n"
    end

    test "--force pisa" do
      path = Path.join(@tmp, "mio.toml")
      File.mkdir_p!(@tmp)
      File.write!(path, "# lo que escribi yo\n")

      assert :ok == Init.run(%{path: path, force: true})
      assert File.read!(path) == template()
    end

    test "el fichero escrito se puede leer como configuracion de verdad" do
      path = Path.join(@tmp, "recien.toml")
      File.mkdir_p!(@tmp)
      Init.run(%{path: path, force: false})

      # Lo que el usuario va a hacer en cuanto lo descomente, hecho aqui.
      text = File.read!(path) <> "\n[model.coder]\ntype = \"local\"\n"
      File.write!(path, text)
      assert {:ok, %{"model" => %{"coder" => %{"type" => "local"}}}} = ConfigFile.load(path)
    end
  end

  # `Template.render/0` devuelve `{:ok, contenido} | {:error, razon}` porque el
  # esqueleto se valida a si mismo. Los tests que comparan CONTENIDO usan
  # `build/0`, que es el cuerpo sin validar: lo que se compara es el texto.
  defp template do
    {:ok, contents} = Candil.Config.Template.render()
    contents
  end
end
