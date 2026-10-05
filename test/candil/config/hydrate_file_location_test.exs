defmodule Candil.Config.HydrateFileLocationTest do
  @moduledoc """
  The `[model.X.source]` table is where a real toml puts the file.

  `model_dir` and `filename` are what `Candil.Engine.Server` joins together to
  build `--model`, and they were only ever read from `[model.X]` — keys no
  hand-written toml has, because the documented format puts the file under
  `[model.X.source]` as `file` and `dest`.

  So the model hydrated with `model_dir: nil, filename: nil`, and
  `Path.join(nil, nil)` took the engine's GenServer down inside its `init/1`.
  Nothing raised at load time, `doctor` reported "6/6 descargados" because it
  reads the source, and `models info` printed the right path because it also
  reads the source. Only the launch read the empty fields.

  Every spec here is the shape of a real `candil.toml`, not a convenient one.
  """
  use ExUnit.Case, async: true

  alias Candil.{Config.Hydrate, Store}

  @coder %{
    "type" => "local",
    "engine" => "llama_cpp",
    "source" => %{
      "kind" => "huggingface",
      "repo" => "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
      "file" => "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf",
      "dest" => "~/models/gguf"
    }
  }

  test "el model_dir sale del dest del source, ya expandido" do
    model = one(:coder, @coder)

    # `hydrate/1` pasa el documento por `Config.File.expand/1` antes de esto, asi
    # que aqui `~` ya no existe. Sin esa expansion la ruta seria
    # `<cwd>/~/models/gguf/...`, que es un directorio llamado «~».
    assert model.model_dir == Path.expand("~/models/gguf")
    refute String.starts_with?(model.model_dir, "~")
  end

  test "el filename sale del file del source" do
    assert one(:coder, @coder).filename == "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
  end

  test "`--model` se puede construir, que es para lo que existen" do
    model = one(:coder, @coder)

    # Lo que hacia `Engine.Server.build_args/2` y reventaba la app entera.
    assert Path.join(model.model_dir, model.filename) ==
             Path.expand("~/models/gguf/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf")
  end

  test "dest_name manda sobre file, que es lo que aplana el subdirectorio MTP/" do
    spec = %{
      "engine" => "llama_cpp",
      "source" => %{
        "kind" => "huggingface",
        "file" => "Qwen3.8-27B-UD-Q3_K_XL.gguf",
        "dest" => "~/models/gguf"
      },
      "draft" => %{
        "kind" => "huggingface",
        "file" => "MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
        "dest" => "~/models/gguf",
        "dest_name" => "mtp-Qwen3.8-27B-Q4_0.gguf"
      }
    }

    model = one(:analyst, spec)
    assert model.filename == "Qwen3.8-27B-UD-Q3_K_XL.gguf"
    assert model.draft.dest_name == "mtp-Qwen3.8-27B-Q4_0.gguf"
  end

  test "un source kind=local con path absoluta tambien da model_dir y filename" do
    spec = %{
      "engine" => "llama_cpp",
      "source" => %{"kind" => "local", "path" => "/opt/models/gguf/m.gguf"}
    }

    model = one(:probe, spec)
    assert model.model_dir == "/opt/models/gguf"
    assert model.filename == "m.gguf"
  end

  test "un model_dir explicito gana sobre el dest del source" do
    spec = %{
      "engine" => "llama_cpp",
      "model_dir" => "/mnt/gpu/models",
      "filename" => "x.gguf",
      "source" => %{"kind" => "huggingface", "file" => "y.gguf", "dest" => "/otro"}
    }

    # Quien escribe model_dir a mano sabe algo que el source no dice.
    model = one(:alpha, spec)
    assert model.model_dir == "/mnt/gpu/models"

    # `Config.File.expand/1` ya habia convertido el filename en absoluto, asi
    # que el `--model` que sale es el mismo fichero. Lo que se comprueba aqui es
    # que el dest del source NO gana.
    assert Path.basename(model.filename) == "x.gguf"
    refute String.contains?(model.filename, "otro")
  end

  test "un modelo remoto no inventa ruta" do
    spec = %{"type" => "remote", "provider" => "openai", "name" => "gpt-4o"}

    model = one(:gpt4o, spec)
    assert Map.get(model, :model_dir) == nil
    assert Map.get(model, :filename) == nil
  end

  # El documento de configuracion lleva los modelos bajo la clave "model", y
  # `section/3` devuelve una LISTA ordenada de structs. Un test escrito como
  # `models[:coder]` recibe un MatchError en vez de un fallo legible.
  # `Hydrate.hydrate/1` devuelve la lista de ALIAS registrados, no los structs:
  # los modelos van al Store, que es de donde los lee `Engine.Server`. Asi que
  # el camino que hay que comprobar es el de verdad — hidratar y luego
  # consultar el Store — y no un atajo por el valor devuelto.
  defp one(name, spec) do
    name = to_string(name)
    _ = Hydrate.hydrate(%{"model" => %{name => spec}})

    case Store.get_model(String.to_existing_atom(name)) do
      {:ok, model} -> model
      _ -> flunk("el modelo #{name} ni se hidrató")
    end
  end
end
