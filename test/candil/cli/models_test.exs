defmodule Candil.CLI.ModelsTest do
  @moduledoc """
  `candil models pull` se llevaba el `source` y se dejaba el `draft`.

  Un modelo puede declarar un `draft` —el modelo de decodificación
  especulativa— y entonces **no arranca sin él**: sus `model_args` llevan
  `--model-draft` con la ruta, y si el fichero no está, llama-server responde

      failed to open GGUF file '…/mtp-….gguf' (No such file or directory)
      srv llama_server: exiting due to model loading error

  Antes la dependencia se **declaraba** —el catálogo la traía, `Hydrate` la
  leía, `models info` la mostraba— y no había ninguna manera de bajarla:
  `pull_one/1` miraba solo `model.source`. Medido el 2026-10-15 con `analyst`,
  que es exactamente ese caso: `candil models pull analyst` descarga el modelo
  de 13 GB y el MTP de 1,3 GB se sigue sin bajar.

  Y `candil models remove` solo borraba el `source`, dejando el draft: quitar
  un modelo con draft dejaba 1,3 GB en el disco.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Candil.CLI.Models
  alias Candil.{Model, Source, Store}

  setup do
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    :ok
  end

  defp local_source(path), do: %Source{kind: :local, path: path}

  defp registrar(alias_, opts) do
    base = %Model{alias: alias_, type: :local, engine: :llama_cpp, usage: [:chat]}
    :ok = Store.register_model(struct!(base, opts))
  end

  describe "pull" do
    @tag :tmp_dir
    test "trae tambien el draft cuando el modelo declara uno", %{tmp_dir: tmp_dir} do
      # `kind: :local` no necesita red: `Source.fetch/1` devuelve la ruta tal
      # cual. Asi lo que se mira es la INTENCION —que el pull recorra el draft—
      # y no tener que esperar a que acabe una descarga.
      main = Path.join(tmp_dir, "modelo.gguf")
      draft = Path.join(tmp_dir, "mtp-draft.gguf")
      File.write!(main, "x")
      File.write!(draft, "x")

      registrar(:con_draft, source: local_source(main), draft: local_source(draft))

      salida = capture_io(fn -> Models.pull(["con_draft"]) end)

      assert salida =~ "con_draft draft",
             "el pull no ha pasado por el draft:\n#{salida}"

      assert salida =~ draft, "el pull no ha dicho la ruta del draft:\n#{salida}"
    end

    @tag :tmp_dir
    test "no inventa un draft para el modelo que no lo declara", %{tmp_dir: tmp_dir} do
      main = Path.join(tmp_dir, "modelo.gguf")
      File.write!(main, "x")
      registrar(:sin_draft, source: local_source(main))

      salida = capture_io(fn -> Models.pull(["sin_draft"]) end)

      # Una sola descarga. El nombre del test lleva "draft" dentro, asi que
      # mirar la palabra no dice nada: lo que tiene que pasar es que no haya
      # un SEGUNDO `downloading`, que es lo que seria inventarse un draft.
      descargas = salida |> String.split("\n") |> Enum.count(&String.contains?(&1, "downloading"))

      assert descargas == 1, "descargó #{descargas} veces:\n#{salida}"
      assert salida =~ main
    end
  end

  describe "la ruta del draft" do
    test "sale del draft, no del source" do
      registrar(:con_draft,
        source: local_source("/modelos/modelo.gguf"),
        draft: local_source("/modelos/mtp-draft.gguf")
      )

      {:ok, model} = Store.get_model(:con_draft)

      assert Model.file_path(model) == "/modelos/modelo.gguf"
      assert Model.draft_path(model) == "/modelos/mtp-draft.gguf"
    end

    test "es nil cuando no hay draft" do
      registrar(:sin_draft, source: local_source("/modelos/modelo.gguf"))

      {:ok, model} = Store.get_model(:sin_draft)

      assert Model.draft_path(model) == nil
    end
  end
end
