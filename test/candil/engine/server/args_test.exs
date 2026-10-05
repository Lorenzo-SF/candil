defmodule Candil.Engine.Server.ArgsTest do
  @moduledoc """
  `--cpu` tiene que poner el modelo en CPU, y no solo decirlo.

  Antes no hacia nada: se parseaba, se validaba, salia en el help, y el modelo
  se lanzaba con sus `model_args` intactos. Con `--n-gpu-layers 99` en el
  toml y otra cosa ya cogiendo la tarjeta, el resultado en la maquina del
  usuario fue:

      failed to fit params to free device memory:
        n_gpu_layers already set by user to 99, abort
      allocating 12005.90 MiB on device 0: cudaMalloc failed: out of memory
      error loading model: unable to allocate CUDA0 buffer

  O sea: Candil decia "esto va a CPU" mientras el modelo intentaba subir 12 GB a
  una GPU con 1 GB libres.
  """
  use ExUnit.Case, async: true

  alias Candil.Engine.Server.Args

  describe "sin --cpu" do
    test "no toca nada, ni siquiera el numero de capas" do
      args = ["--n-gpu-layers", "99", "--temp", "0.7"]
      assert Args.for_cpu(args, false) == {args, {[], []}}
    end
  end

  describe "con --cpu" do
    test "pone las capas a 0 en vez de quitarlas" do
      # Quitarlo NO seria lo mismo: sin numero, llama-server ajusta lo que
      # quepa, y "lo que quepa" no es "CPU". Con 99 explicito lo que hay es
      # "intentalo todo, y si no cabe avisa".
      {args, {forced, _unknown}} = Args.for_cpu(["--n-gpu-layers", "99", "--temp", "0.7"], true)

      assert args == ["--n-gpu-layers", "0", "--temp", "0.7"]
      assert forced == ["--n-gpu-layers"]
    end

    test "el orden del argv no se toca: flag, valor, flag, valor" do
      {args, _} = Args.for_cpu(["--n-gpu-layers", "99", "--temp", "0.7", "--top-k", "20"], true)

      assert args == ["--n-gpu-layers", "0", "--temp", "0.7", "--top-k", "20"]
    end

    test "NO re-empareja: un interruptor no come el flag que va detras" do
      # El fallo de las tres primeras versiones. Con
      # ["--no-kv-offload", "--cache-type-k", "q8_0"] agrupar de dos en dos
      # empareja "--no-kv-offload" con "--cache-type-k" y "q8_0" se queda sin
      # su flag. Aqui cada bandera se reconoce por su NOMBRE y no hay
      # emparejamiento, asi que no se puede desplazar nada.
      {args, {forced, _unknown}} =
        Args.for_cpu(["--no-kv-offload", "--cache-type-k", "q8_0", "--temp", "0.7"], true)

      assert args == ["--cache-type-k", "q8_0", "--temp", "0.7"]
      assert forced == ["--no-kv-offload"]
    end

    test "un interruptor conocido no recibe un valor inventado" do
      # "--no-kv-offload 0" salia de mirar la regla por su "offload" antes que
      # la lista de interruptores: un valor puesto a un flag que no lleva.
      {args, _} = Args.for_cpu(["--no-kv-offload", "--temp", "0.7"], true)

      assert args == ["--temp", "0.7"]
    end

    test "los selectores de dispositivo se van con su valor" do
      {args, {forced, _unknown}} = Args.for_cpu(["--device", "CUDA0", "--temp", "0.6"], true)

      assert args == ["--temp", "0.6"]
      assert forced == ["--device"]
    end

    test "cualquier flag de capas va a 0, este donde este" do
      # Sin ancla al final: `--n-gpu-layers-draft` lleva "layers" por el medio,
      # y con el `$` se colaba entero — modelo a CPU y draft con la tarjeta.
      {args, {forced, _unknown}} =
        Args.for_cpu(["--n-gpu-layers-draft", "-1", "--mmproj-offload", "1"], true)

      assert args == ["--n-gpu-layers-draft", "0", "--mmproj-offload", "0"]
      assert forced == ["--n-gpu-layers-draft", "--mmproj-offload"]
    end

    test "lo que huele a GPU y no se conoce, se DICE" do
      # Nada puede saber todos los flags de un programa que no es nuestro. Lo
      # que no se reconoce y huele a GPU pasa tal cual y se reporta: una regla
      # que hace la mitad del trabajo en silencio es peor que una que dice
      # cual no hace.
      {args, {_forced, unknown}} = Args.for_cpu(["--cuda-streams", "2", "--temp", "0.7"], true)

      assert args == ["--cuda-streams", "2", "--temp", "0.7"]
      assert unknown == ["--cuda-streams"]
    end

    test "el muestreo y la cache no se tocan: en CPU significan lo mismo" do
      original = [
        "--temp",
        "0.7",
        "--top-p",
        "0.8",
        "--top-k",
        "20",
        "--cache-type-k",
        "q8_0",
        "--cache-type-v",
        "q8_0",
        "--jinja",
        "--reasoning-format",
        "deepseek",
        "--chat-template-kwargs",
        ~s({"enable_thinking": false})
      ]

      assert Args.for_cpu(original, true) == {original, {[], []}}
    end

    test "un argv impar de verdad no se corrompe" do
      # Un valor sin flag delante se queda donde esta. Moverlo seria peor que
      # dejarlo: un argv mal escrito que el usuario puede ver, y no uno que
      # Candil ha rehecho sin avisar.
      original = ["--jinja", "suelto", "--temp", "0.7"]

      assert {^original, _} = Args.for_cpu(original, true)
    end

    test "una lista vacia sigue siendo una lista vacia" do
      assert Args.for_cpu([], true) == {[], {[], []}}
    end
  end
end
