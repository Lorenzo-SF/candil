defmodule Candil.ModelTest do
  use ExUnit.Case, async: true

  alias Candil.Model

  describe "validate/1" do
    test "accepts valid local model" do
      model = %Model{
        alias: :test,
        type: :local,
        model_dir: "/models",
        filename: "test.gguf",
        engine: :llama
      }

      assert Model.validate(model) == :ok
    end

    test "rejects model_dir with path traversal" do
      model = %Model{
        alias: :bad,
        type: :local,
        model_dir: "../../etc",
        filename: "test.gguf",
        engine: :llama
      }

      assert {:error, reasons} = Model.validate(model)
      assert Enum.any?(reasons, &String.contains?(&1, "path traversal"))
    end

    test "rejects filename with path traversal" do
      model = %Model{
        alias: :bad,
        type: :local,
        model_dir: "/models",
        filename: "../../etc/passwd",
        engine: :llama
      }

      assert {:error, reasons} = Model.validate(model)
      assert Enum.any?(reasons, &String.contains?(&1, "path traversal"))
    end
  end

  describe "file_path/1" do
    test "returns nil for remote models" do
      model = %Model{alias: :remote, type: :remote, name: "gpt-4", provider: :openai}
      assert Model.file_path(model) == nil
    end

    test "joins model_dir and filename for local models" do
      model = %Model{
        alias: :test,
        type: :local,
        model_dir: "/models",
        filename: "test.gguf",
        engine: :llama
      }

      assert Model.file_path(model) == "/models/test.gguf"
    end

    test "returns nil for invalid model" do
      assert Model.file_path(%{}) == nil
    end
  end

  # La `description` no es un campo mas: es lo UNICO que la capa `:embedding`
  # del router tiene para comparar con un prompt. Sin ella, esa capa no compara
  # nada y devuelve `:miss`, y el usuario no tiene forma de saber por que.
  describe "description" do
    test "es un campo del struct, y por defecto no esta" do
      assert %Model{type: :local, description: nil} = %Model{alias: :x, type: :local}
    end

    test "guarda lo que le han puesto, sin recortarlo ni corregirlo" do
      model = %Model{alias: :x, type: :local, description: "  escribe codigo  "}
      assert model.description == "  escribe codigo  "
    end

    test "un modelo sin descripcion sigue siendo valido" do
      # Si `validate/1` exigiera la descripcion, ningun modelo de los que ya
      # estan en el mundo pasaria, y la exigibilidad de un campo opcional se
      # acaba notando cuando hay que meterla en tres sitios.
      assert Model.validate(%Model{
               alias: :x,
               type: :local,
               engine: :llama,
               model_dir: "/models",
               filename: "x.gguf"
             }) == :ok
    end
  end
end
