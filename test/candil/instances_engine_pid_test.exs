defmodule Candil.InstancesEnginePidTest do
  @moduledoc """
  Un registro que se **escribe** con un campo y se **lee** sin el es un bug
  invisible: el fichero en disco dice la verdad y el programa no la ve.

  Con `engine_pid` paso exactamente eso. `build/7` lo escribia,
  `to_instance/1` —que elige los campos a mano al decodificar— lo tiraba, y
  `candil status` ponia un guion en la columna `VRAM` mientras el `instances.json`
  de al lado tenia el numero. Sin este test, el unico sintoma es una celda vacia
  y nada mas.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Candil.Instances

  defp punto(tmp_dir) do
    previous = System.get_env("CANDIL_DATA_DIR")
    System.put_env("CANDIL_DATA_DIR", Path.join(tmp_dir, "data"))
    on_exit(fn -> if previous, do: System.put_env("CANDIL_DATA_DIR", previous) end)
  end

  describe "el viaje entero, por el disco" do
    test "engine_pid se escribe y se vuelve a leer", %{tmp_dir: tmp_dir} do
      punto(tmp_dir)

      instancia =
        Instances.build("coder", 9999, "llama_cpp", 100, true, "127.0.0.1", 200)

      assert instancia.engine_pid == 200
      assert :ok = Instances.put({"coder", 9999}, instancia)

      # Por el FICHERO, no por la variable: el bug estaba en el decodificador, y
      # una asercion sobre la struct que acabas de construir no lo veria.
      [leida | _] = Instances.all()

      assert leida.engine_pid == 200
    end

    test "un registro viejo, sin engine_pid, se lee sin reventar", %{tmp_dir: tmp_dir} do
      punto(tmp_dir)

      # Escrito a mano, como lo dejaria una version anterior. Sin el campo.
      data = Path.join([System.tmp_dir!(), "candil-viejo-#{System.unique_integer([:positive])}"])

      # El registro vive en `<data_dir>/run/instances.json`, no en la raiz del
      # data dir. Escribirlo en el sitio equivocado daria `[]` y el test
      # pasaria por el motivo equivocado.
      run = Path.join(data, "run")
      File.mkdir_p!(run)

      File.write!(
        Path.join(run, "instances.json"),
        Jason.encode!([
          %{
            "model" => "coder",
            "port" => 9999,
            "pid" => 100,
            "owner" => %{"kind" => "pid", "pid" => 100},
            "started_at" => "2026-10-15T09:00:00Z",
            "healthy" => true
          }
        ])
      )

      System.put_env("CANDIL_DATA_DIR", data)

      assert Instances.path() == Path.join(run, "instances.json")
      assert [leida] = Instances.all()
      assert leida.engine_pid == nil
      assert leida.model == "coder"
    end

    test "el dueño y el motor son dos procesos distintos", %{tmp_dir: tmp_dir} do
      punto(tmp_dir)

      instancia =
        Instances.build("coder", 9999, "llama_cpp", 4_140_920, true, "127.0.0.1", 4_140_992)

      # El motor es un nieto del dueno (`holder -> sh -> llama-server`), y solo
      # el segundo es el pid que `nvidia-smi` reconoce. Confundirlos es lo que
      # hacia que la columna saliera siempre con un guion.
      assert instancia.pid == 4_140_920
      assert instancia.engine_pid == 4_140_992
    end
  end
end
