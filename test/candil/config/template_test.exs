defmodule Candil.Config.TemplateTest do
  @moduledoc """
  El esqueleto que `candil init` escribe tiene que hablar de las claves nuevas.

  La plantilla se GENERA desde el schema, y esa es la razon de que exista: un
  esqueleto escrito a mano se queda viejo el dia que alguien anade una clave, y
  uno viejo es peor que ninguno, porque parece autoritativo y esta mal
  exactamente donde hacia falta. El problema de "se queda viejo" tiene dos
  caras, y la segunda es la que no se ve: una clave que existe en el schema y
  no aparece en el esqueleto, porque nadie se acordo de anadirla. Eso es
  exactamente lo que se comprueba aqui.
  """
  use ExUnit.Case, async: true

  alias Candil.Config.{Schema, Template}

  setup_all do
    {:ok, contents} = Template.render()
    %{contents: contents}
  end

  test "el esqueleto se valida a si mismo antes de salir", %{contents: contents} do
    # `render/0` ya lo hace, y el que protege es el que ejecuta `candil init`.
    # Este test esta para que el fallo se vea en la suite y no en la maquina de
    # quien lo ejecuta.
    assert {:ok, %{}} = Toml.decode(contents)
  end

  test "el esqueleto menciona TODAS las secciones que el schema valida", %{
    contents: contents
  } do
    for section <- Schema.sections() do
      assert contents =~ "[#{section}", "el esqueleto no menciona la seccion [#{section}]"
    end
  end

  test "el esqueleto declara `description`, y dice para que sirve" do
    # La clave que la capa `:embedding` del router necesita y que nadie
    # entenderia sin una linea de contexto: no es la carta de presentación del
    # modelo, es el texto que se compara con el prompt.
    assert Template.build() =~ "description"
  end

  test "el esqueleto declara los dos nombres que encienden las capas :llm y :embedding" do
    contents = Template.build()

    assert contents =~ "classifier"
    assert contents =~ "embedder"
    assert contents =~ "enable_llm_classifier"
  end

  test "el esqueleto esta COMMENTED OUT entero: es valido y no hace nada" do
    # Un esqueleto con un modelo vivo apuntando a una descarga de 17 GB convierte
    # la primera ejecucion en una tarde. Decodificado, no hay NADA: cero
    # secciones, cero claves.
    assert {:ok, %{}} = Toml.decode(Template.build())
  end
end
