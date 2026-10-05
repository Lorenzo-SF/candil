defmodule Candil.Engine.Server.Args do
  @moduledoc """
  What `--cpu` does to a model's arguments.

  ## The rule, and the limit

  `--cpu` means *everything on CPU*: the model, its draft, its mmproj, and
  whatever llama.cpp drags along. The user's words, and the right reading.

  It failed before because `--cpu` was parsed, validated, documented — and read
  nowhere. The model launched with its own `model_args` and produced this:

      failed to fit params to free device memory:
        n_gpu_layers already set by user to 99, abort
      allocating 12005.90 MiB on device 0: cudaMalloc failed: out of memory
      error loading model: unable to allocate CUDA0 buffer

  Candil said "this goes on CPU" while the model tried to put 12 GB on a GPU
  that already had 14 GB taken. The first line is the giveaway: llama-server
  would have fitted itself to the free memory if the number had not been
  pinned in the toml.

  So `--cpu` sets the layer count to 0 — not "whatever fits", which is a
  different thing and is what llama.cpp already does on its own.

  ## Why this only removes and never re-pairs

  Three earlier versions of this module grouped the arguments in pairs to find
  each flag's value, and every one of them was wrong: an argv is not a list of
  pairs. `--no-kv-offload` is one element, `--cache-type-k q8_0` is two, and
  nothing in the list says which. Guessing produced argv that no one wrote —
  `--n-gpu-layers 0 0.7 --temp`, a value with no flag in front of it — and in
  one case a loop that never returned.

  So there is no pairing at all. Every flag is handled by NAME, and each one
  is either removed, set to zero, or left exactly where it was. Nothing can
  shift because nothing is ever re-grouped.

  The cost is honest: a flag this table does not name is left alone. It is not
  guessed at, and if it smells like a device flag it is **reported** rather
  than passed over in silence:

      --cpu en analyst: no conozco "--cuda-streams" y huele a GPU.
      Pasa tal cual. Dime que significa y lo anado a la tabla.
  """

  # Interruptores que solo tienen sentido con GPU delante y que NO llevan valor.
  # `--flash-attn` no esta: en algunas compilaciones significa algo en CPU, y
  # decidir lo contrario seria inventarse la version del otro.
  @valueless ~w(--no-kv-offload --no-warmup --cache-reuse-all)

  # Selectores de dispositivo. Se van con su valor: un `--device` suelto se
  # comeria el argumento siguiente.
  @with_value ~w(--device --device-agnostic --split-mode --main-gpu --tensor-split --fit --rpc)

  # Cuantas capas van a la GPU, de lo que sea. La lista NO esta anclada al
  # final a proposito: `--n-gpu-layers-draft` lleva "layers" por el medio, y
  # con un ancla se colaba entero — modelo a CPU y draft con la tarjeta, que es
  # el bug con otro flag delante.
  @zeroed ~w(--n-gpu-layers --n-gpu-layers-draft --mmproj-offload)

  @doc """
  Rewrites `args` for a CPU run.

  Returns `{args, {forced, unknown}}`: the new arguments, the flags that were
  changed or removed, and the ones that smell like a device flag and are not
  in the table. The caller is expected to say both out loud.
  """
  @spec for_cpu([binary()], boolean()) :: {[binary()], {[binary()], [binary()]}}
  def for_cpu(args, false), do: {args, {[], []}}
  def for_cpu(args, true), do: walk(args, [], [], [])

  # Se antepone y se le da la vuelta UNA vez al final, sobre la lista PLANA de
  # argumentos. Y no hay emparejamiento en ningun sitio: cada bandera se
  # reconoce por su nombre y consume su propio valor si lo tiene. Por eso el
  # orden no se puede romper — no hay nada que desplace a nada.
  # Se voltea la lista de TROZOS, no la de argumentos. Anteponer dos elementos
  # a una lista plana y darle la vuelta al final invierte el orden DENTRO de la
  # pareja: "--temp 0.6" sale "0.6 --temp". Con trozos, el volteo solo cambia el
  # orden entre pares, que es lo unico que tiene que cambiar.
  defp walk([], chunks, forced, unknown) do
    {chunks |> Enum.reverse() |> List.flatten(), {Enum.reverse(forced), unknown}}
  end

  defp walk([flag | rest], chunks, forced, unknown) when flag in @valueless do
    walk(rest, chunks, [flag | forced], unknown)
  end

  defp walk([flag, _value | rest], chunks, forced, unknown) when flag in @with_value do
    walk(rest, chunks, [flag | forced], unknown)
  end

  defp walk([flag, _value | rest], chunks, forced, unknown) when flag in @zeroed do
    # El valor se pone a cero y el flag se queda. Un `99` que sobrevive al
    # lado de un `0` es justo el bug original: llama-server avisa "already set
    # by user" y aborta.
    walk(rest, [[flag, "0"] | chunks], [flag | forced], unknown)
  end

  defp walk([flag, value | rest], chunks, forced, unknown) do
    walk(rest, [[flag, value] | chunks], forced, note(flag, unknown))
  end

  # Un valor sin flag delante: el argv del usuario esta mal escrito. Se deja
  # como esta y se dice, porque un valor suelto que se mueve de sitio es peor
  # que un valor suelto que se queda.
  defp walk([value], chunks, forced, unknown) do
    # Se sigue hasta el final en vez de devolver aqui: devolver desde esta
    # clausula aplicaba el volteo una segunda vez, y el argv salia ROTADO —
    # el primer elemento al final y todos los demas en su orden, que es la
    # forma mas dificil de detectar de tener un argv estropeado.
    walk([], [value | chunks], forced, unknown)
  end

  defp note(flag, unknown) do
    if device_flavoured?(flag), do: [flag | unknown], else: unknown
  end

  defp device_flavoured?(flag) do
    String.contains?(flag, "gpu") or String.contains?(flag, "cuda") or
      String.contains?(flag, "mmproj") or String.contains?(flag, "device") or
      String.contains?(flag, "split")
  end
end
