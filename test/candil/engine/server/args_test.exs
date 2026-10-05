defmodule Candil.Engine.Server.ArgsTest do
  @moduledoc """
  `--cpu` tiene que funcionar, y tiene que funcionar como ropero.

  Ropero lo llevaba haciendo bien, y su `start_model` lo explica en un
  comentario: los flags de CPU van **al final** del comando, porque
  llama-server se queda con la **última** aparición de un flag repetido. Eso
  es todo el truco, y es por eso que aquí no se reescribe el argv del modelo:
  reescribirlo exige saber qué flags de llama.cpp llevan valor, y esa tabla no
  está en ninguna parte.

  Cuatro versiones de este módulo lo intentaron por la vía difícil y las
  cuatro estaban mal: un argv no es una lista de parejas —`--no-kv-offload` es
  un elemento y `--cache-type-k q8_0` son dos— y adivinarlo produjo un valor
  sin su flag delante, un argv invertido, un bucle infinito y uno rotado.
  """
  use ExUnit.Case, async: true

  alias Candil.Engine.Server.Args

  describe "sin --cpu" do
    test "no toca nada, ni un elemento" do
      args = ["--n-gpu-layers", "99", "--temp", "0.7"]
      assert Args.for_cpu(args, false) == {args, []}
    end
  end

  describe "con --cpu" do
    test "añade --n-gpu-layers 0 al FINAL" do
      # Al final, no en su sitio: llama-server gana el último. Reescribir el
      # 99 del modelo en su sitio tambien funcionaria, pero exige saber qué
      # flags llevan valor para no descuadrar el resto. Añadir no necesita
      # saber nada.
      {args, _appended} = Args.for_cpu(["--n-gpu-layers", "99", "--temp", "0.7"], true)

      # Lo que se añade son 4 elementos: el flag de capas y el de hilos.
      assert ["--n-gpu-layers", "0", "--threads", nproc()] == Enum.slice(args, -4, 4)
    end

    test "los args del modelo quedan intactos y en su orden" do
      original = [
        "--n-gpu-layers",
        "99",
        "--no-kv-offload",
        "--n-cpu-moe",
        "30",
        "--cache-type-k",
        "q8_0",
        "--jinja",
        "--temp",
        "0.7"
      ]

      {args, _} = Args.for_cpu(original, true)

      # Todo lo de ropero sigue ahí, incluido el 99. Gana el 0 de detrás, que
      # es exactamente como lo hace ropero.
      assert Enum.take(args, length(original)) == original
    end

    test "no inventa valores ni reordena nada: solo crece por la derecha" do
      original = ["--n-gpu-layers", "-1", "--n-gpu-layers-draft", "-1", "--temp", "0.7"]
      {args, _} = Args.for_cpu(original, true)

      assert Enum.take(args, length(original)) == original
      assert length(args) == length(original) + 4
    end

    test "también añade --threads, que en CPU no es decoración" do
      # Un 27B en CPU va limitado por hilos. Ropero le pasa nproc, y sin eso
      # tienes un modelo que técnicamente está en CPU y tarda cuatro veces más.
      {args, _} = Args.for_cpu(["--temp", "0.7"], true)

      assert "--threads" in args
      n = args |> Enum.reverse() |> Enum.find(&(&1 != "--threads"))
      assert {n, _} = Integer.parse(n)
      assert n >= 1
    end

    test "los threads del modelo no se pisan: gana el que va detrás" do
      {args, _} = Args.for_cpu(["--threads", "12"], true)

      assert args == ["--threads", "12", "--n-gpu-layers", "0", "--threads", nproc()]
    end

    test "dice qué ha añadido, para no pisar la config de nadie en silencio" do
      {_args, appended} = Args.for_cpu([], true)

      # "--n-gpu-layers 0" va como un texto, y los hilos como flag y valor.
      assert length(appended) == 3
      assert Enum.any?(appended, &(&1 =~ "n-gpu-layers"))
    end

    test "una lista vacia de argumentos no es un caso raro" do
      {args, _} = Args.for_cpu([], true)
      assert args == ["--n-gpu-layers", "0", "--threads", nproc()]
    end
  end

  defp nproc do
    {out, 0} = System.cmd("nproc", [])
    String.trim(out)
  end
end
