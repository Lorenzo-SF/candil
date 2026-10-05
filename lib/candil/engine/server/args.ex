defmodule Candil.Engine.Server.Args do
  @moduledoc """
  What `--cpu` does: **append, and get out of the way**.

  ## Ropero is the reference, and this copies it

  `ropero` has done `--cpu` correctly all along, and its `start_model` says
  exactly how:

      # Override --cpu al FINAL del cmd para ganar sobre args del modelo.
      # Ojo: --cpu mueve el DISPOSITIVO, no el puerto.
      cmd+=("--n-gpu-layers" 0)
      cmd+=("--threads" "$_nproc")

  Two facts hide in that comment, and both of them I had wrong:

  1. **llama-server uses the LAST occurrence of a repeated flag.** Appending is
     how you win. Rewriting the model's own value in place is not needed and
     only creates chances to corrupt an argv.

  2. **`--cpu` moves the device, not the port.** A model with a pinned
     `MODEL_PORT` keeps it. Ropero only defaults the port to the CPU slot when
     the model has none. That is a deliberate rule, not an accident.

  And `--threads` is not decoration: a 27B on CPU is thread-bound, and ropero
  hands it `nproc`. Without it you get a model that is technically on CPU and
  takes four times as long.

  ## What this does NOT do

  It does not strip `--no-kv-offload`, nor `--n-cpu-moe`, nor anything else the
  model declares. Ropero doesn't, and its CPU runs work. Three earlier
  versions of this module did try, and all three were wrong: an argv is not a
  list of pairs — `--no-kv-offload` is one element and `--cache-type-k q8_0`
  are two — so re-pairing produced a value with no flag in front of it, then a
  reversed argv, then an infinite loop, then a rotated one. Every one of those
  was me guessing at a table of llama.cpp's flags that I do not have.

  Appending needs no such table.
  """

  @doc """
  Appends the CPU flags to `args`.

  Returns `{args, appended}` where `appended` is what was added, so the caller
  can say it out loud. Overriding somebody's configuration in silence is how
  you lose their trust the day it goes wrong.
  """
  @spec for_cpu([binary()], boolean()) :: {[binary()], [binary()]}
  def for_cpu(args, false), do: {args, []}

  def for_cpu(args, true) do
    threads = ["--threads", Integer.to_string(cpu_count())]
    {args ++ ["--n-gpu-layers", "0"] ++ threads, ["--n-gpu-layers 0"] ++ threads}
  end

  # `nproc`, con el mismo criterio que ropero: si no hay forma de saberlo, 8.
  defp cpu_count do
    case System.cmd("nproc", []) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, _} when n > 0 -> n
          _ -> 8
        end

      _ ->
        8
    end
  rescue
    # Sin `nproc` —macOS— la cuenta sale de la maquina, que es lo que hace
    # ropero tambien al no tener `nproc`.
    _kind -> System.schedulers_online()
  end
end
