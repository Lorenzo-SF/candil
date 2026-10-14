defmodule Candil.CLI.LifecycleTest do
  @moduledoc """
  Dos cosas de `Candil.CLI.Lifecycle` que eran teatro.

  Ninguna de las dos se hacia notar por fallar: una **mintiendo** y la otra
  **prometiendo una proteccion que no tenia**.
  """

  use ExUnit.Case, async: false

  alias Candil.CLI.Lifecycle
  alias Candil.{Model, Store}

  setup do
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    :ok
  end

  defp registrar(alias_, gpu_layers) do
    :ok =
      Store.register_model(%Model{
        alias: alias_,
        type: :local,
        engine: :llama_cpp,
        model_dir: "/modelos",
        filename: "#{alias_}.gguf",
        usage: [:chat],
        gpu_layers: gpu_layers
      })
  end

  describe "la columna que decia donde estaba el modelo" do
    # Antes: `rem(port, 100) >= 90 -> "dGPU"`. Medido el 2026-10-14 sobre el
    # catalogo real, los seis modelos caian ahi y **todos** salian "dGPU",
    # incluidos dos que el propio fichero marcaba `tags = ["cpu", …]`.

    test "dice las capas que van a GPU, no lo que adivina del puerto" do
      registrar(:todo_en_gpu, -1)
      registrar(:solo_cpu, 0)
      registrar(:unas_capas, 20)

      assert Lifecycle.gpu_layers("todo_en_gpu") =~ "todas (-1)"
      assert Lifecycle.gpu_layers("solo_cpu") == "0 · CPU"
      assert Lifecycle.gpu_layers("unas_capas") == "20 de GPU"
    end

    test "`-1` no se dice 'dGPU': significa las que quepan" do
      # Es la diferencia que hacia que la columna fuera falsa. `-1` es
      # «las que quepan», y si no cabe el modelo se va partly a CPU.
      registrar(:colgado, -1)

      refute Lifecycle.gpu_layers("colgado") =~ "dGPU"
      assert Lifecycle.gpu_layers("colgado") =~ "que"
    end

    test "si no lo sabe, lo dice" do
      assert Lifecycle.gpu_layers("modelo_que_no_existe") == "—"
    end
  end

  describe "safe_alias/1, que no era safe" do
    # Era `defp safe_alias(name), do: to_alias(name)`, y `to_alias` es
    # `String.to_atom/1`. Un nombre tecleado creaba un atomo que no se
    # recoge nunca — y el comentario de al lado ya decia que no lo hacia.

    test "devuelve el alias si existe" do
      registrar(:ya_existe, -1)

      assert Lifecycle.safe_alias("ya_existe") == :ya_existe
    end

    test "devuelve nil en vez de crear un atomo para un nombre inventado" do
      antes = :erlang.system_info(:atom_count)
      refute Lifecycle.safe_alias("alias-que-nadie-se-ha-inventado-jamas")
      # Y el atomo no se ha creado.
      assert :erlang.system_info(:atom_count) == antes

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("alias-que-nadie-se-ha-inventado-jamas")
      end
    end

    test "y con un nombre que ya es atomo, lo devuelve tal cual" do
      registrar(:ya_es_atom, -1)

      assert Lifecycle.safe_alias(:ya_es_atom) == :ya_es_atom
    end
  end
end
