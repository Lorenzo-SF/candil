defmodule Candil.FakeGPU do
  @moduledoc """
  Un `nvidia-smi` de mentira, para que los tests no dependan de la máquina.

  ## Por qué hace falta

  `Candil.Detector.Devices` mide el hardware real con `nvidia-smi`. Un test que
  depende de eso depende de la máquina donde corre: en CI no hay GPU, y en
  local puede estar ocupada por otra sesión.

  Medido el 2026-10-21: `resource_foreign_test.exs` falló en CI con
  `{:error, :capacity_unknown}` —no por un fallo del código, sino porque el
  runner no tiene GPU— y `cpu_args_test.exs` falló en local cuando otra
  sesión tenía la tarjeta al 99 %.

  La solución no es saltarse el test (`@tag :skip`), que dejaría el caso sin
  cubrir: es **poner delante un `nvidia-smi` de mentira** que diga lo que el
  test necesita. El código de producción no cambia, y el test además puede
  reproducir un caso que en la máquina real es difícil: la GPU llena.

  ## Cómo se usa

      setup do
        FakeGPU.install(tmp_dir, total_mb: 16_303, free_mb: 16_000)
        on_exit(&FakeGPU.uninstall/0)
        :ok
      end

  `free_mb` es la memoria libre **de verdad**: el resto (los procesos de otra
  sesión) es exactamente lo que Candil tiene que descontar como titular
  `:foreign`.

  ## Lo que no hace

  No cambia el `nvidia-smi` real del sistema: solo se pone delante en el
  `PATH` del proceso de tests, y `uninstall/0` lo devuelve. Como el `PATH` es
  global, los ficheros que lo usan tienen que ser `async: false`: los tests
  sincronos de ExUnit corren de uno en uno.
  """

  @uuid "GPU-00000000-0000-0000-0000-000000000000"

  @doc """
  Escribe un `nvidia-smi` de mentira en `dir` y lo pone delante en el `PATH`.

  Con `no_gpu: true`, el binario **falla**, que es lo que ve una máquina sin
  NVIDIA: `nvidia_available?/0` da falso y no hay devices que colocar.

  Devuelve el `PATH` anterior, por si quien llama quiere guardarlo.
  """
  @spec install(Path.t(), keyword()) :: String.t() | nil
  def install(dir, opts \\ []) do
    total = Keyword.get(opts, :total_mb, 16_303)
    free = Keyword.get(opts, :free_mb, 16_000)

    bin_dir = Path.join(dir, "fake-bin")
    File.mkdir_p!(bin_dir)

    script = Path.join(bin_dir, "nvidia-smi")
    content = if Keyword.get(opts, :no_gpu, false), do: no_gpu_script(), else: script(total, free)
    File.write!(script, content)
    File.chmod!(script, 0o755)

    previous = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (previous || ""))
    push(previous)

    previous
  end

  @doc """
  Devuelve el `PATH` al estado anterior.
  """
  @spec uninstall() :: :ok
  def uninstall do
    case pop() do
      nil -> :ok
      previous -> System.put_env("PATH", previous || "")
    end
  end

  # Una máquina sin NVIDIA: el binario existe pero falla, que es lo que ve
  # `nvidia_available?/0` cuando `nvidia-smi -L` no lista tarjetas.
  defp no_gpu_script do
    """
    #!/bin/sh
    exit 1
    """
  end

  # El script responde a las cuatro preguntas que le hace Candil:
  #
  #   -L                                        → hay NVIDIA
  #   --query-gpu=index,name,memory.total,memory.free → la GPU y su memoria
  #   --query-gpu=index,uuid                   → el mapa UUID -> índice
  #   --query-compute-apps=...                 → ningún proceso en la GPU
  #
  # La última es la que hace que el proceso de otra sesión **no** se cuele en
  # el ledger: los tests que necesitan esa memoria la ponen a mano, como
  # titular `:foreign`.
  defp script(total, free) do
    """
    #!/bin/sh
    case "$*" in
      *"-L"*)
        echo "GPU 0: NVIDIA GeForce RTX 5080 (UUID: #{@uuid})"
        ;;
      *"--query-gpu=index,name,memory.total,memory.free"*)
        echo "0, NVIDIA GeForce RTX 5080, #{total}, #{free}"
        ;;
      *"--query-gpu=index,uuid"*)
        echo "0, #{@uuid}"
        ;;
      *)
        # `--query-compute-apps`: no hay ningún proceso usando la GPU.
        ;;
    esac
    exit 0
    """
  end

  # Una pila, porque dos ficheros pueden instalar el suyo y cada uno
  # devuelve el `PATH` al suyo al salir. El `on_exit` corre en otro proceso,
  # así que esto no puede vivir en el dictionary del proceso de test.
  defp push(previous) do
    agent = ensure_agent()
    Agent.update(agent, fn stack -> [previous | stack] end)
  end

  defp pop do
    agent = ensure_agent()

    Agent.get_and_update(agent, fn
      [head | tail] -> {head, tail}
      [] -> {nil, []}
    end)
  end

  defp ensure_agent do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, pid} = Agent.start(fn -> [] end, name: __MODULE__)
        pid

      pid ->
        pid
    end
  end
end
