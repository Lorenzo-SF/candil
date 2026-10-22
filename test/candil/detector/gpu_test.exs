defmodule Candil.Detector.GPUTest do
  @moduledoc """
  `System.cmd/3` **no devuelve un error cuando el binario no existe: lanza
  una `ErlangError` con `:enoent`**. Y hay binarios que no están en todas las
  máquinas: `nvcc` es el toolkit de CUDA, y se puede tener el driver de
  NVIDIA sin el toolkit.

  Medido el 2026-10-21: en el runner de CI (que tiene `nvidia-smi` y no tiene
  `nvcc`), Candil reventaba con un `ErlangError` al detectar el hardware. Es un
  crash de producción, no un problema de tests: le pasaba a cualquiera con una
  GPU y sin el toolkit instalado.
  """

  use ExUnit.Case, async: true

  alias Candil.Detector.GPU

  describe "cmd/2" do
    test "un binario que no existe es :not_found, no una excepcion" do
      assert GPU.cmd("candil-no-existe-este-binario", ["--version"]) == :not_found
    end

    test "un binario que existe pero no se puede ejecutar no revienta" do
      # El caso del shebang que apunta a un interprete que no existe —un
      # venv borrado, un `/usr/bin/env` de otra maquina—: el archivo esta ahi
      # y es ejecutable, pero el kernel no lo puede arrancar. Lo que importa es
      # que **no reviente**: o sale un error de verdad o dice `:not_found`, pero
      # un `ErlangError` seria un crash de produccion.
      dir = Path.join(System.tmp_dir!(), "candil-gpu-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "candil-roto")
      File.write!(path, "#!/bin/candil-no-existe-este-interprete\n")
      File.chmod!(path, 0o755)

      on_exit(fn -> File.rm_rf(dir) end)

      assert match?({_out, _rc}, GPU.cmd(path, []))
    end

    test "un binario que existe y funciona devuelve su salida" do
      assert {out, 0} = GPU.cmd("sh", ["-c", "echo hola"])
      assert out =~ "hola"
    end
  end

  describe "detect_cuda_version/0" do
    test "no revienta aunque no haya nvcc" do
      # Lo que se comprueba aqui es lo unico que se puede comprobar en una
      # maquina cualquiera: que la funcion **responde**. Su valor depende de si
      # la maquina tiene el toolkit, y eso no es un hecho del codigo.
      assert is_binary(GPU.detect_cuda_version()) or is_nil(GPU.detect_cuda_version())
    end
  end
end
