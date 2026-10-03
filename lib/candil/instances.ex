defmodule Candil.Instances do
  @moduledoc """
  The on-disk record of which engines are running, and who owns them.

  The `Candil.EnginePool` answers "what is alive **in this VM**". That is not
  the same question as "what is alive on this machine", and after a `--detach`
  it stops being the question at all: the owner is a different process, in a
  different VM, and the only thing the second `candil` can do is read a file.

  So this is a file:

      <data_dir>/run/
        instances.json    [{model, port, engine, pid, owner, started_at, healthy}]
        ad-hoc-ports      one port per line, the ones given with --port

  ## The owner is a tagged tuple, and the second variant is the point

      %{kind: :pid, pid: 4821}          # v4: a process. We signal it.
      # %{kind: :socket, path: path}    # v5: a daemon. We talk to its socket.

  The second clause is not written because there is nothing to write yet. It
  is not written because when there IS a daemon, `candil stop` must not be
  rewritten either, and a `case` that already names the future variant is the
  cheapest possible door. Cost: six lines, now, instead of a redesign later.

  ## Atomic writes, pruned reads

  A write is temp-file-plus-rename, because `instances.json` is the file two
  processes read to decide whether to kill something. A truncated one is worse
  than a missing one: it says "nothing is running" when the truth is "I don't
  know", and the difference is an orphaned `llama-server` holding 20 GB of VRAM.

  A read prunes entries whose pid no longer exists. `nohup` leaves zombies, and
  an unpruned file lies about exactly that.
  """

  @typedoc """
  Who owns an instance. One variant today; the second is the door to a daemon.
  """
  @type owner :: %{kind: :pid, pid: pos_integer()}

  @type instance :: %{
          model: binary(),
          port: pos_integer(),
          engine: binary() | nil,
          pid: pos_integer() | nil,
          owner: owner(),
          started_at: binary(),
          healthy: boolean()
        }

  @doc """
  Where Candil keeps its run state.

  `CANDIL_DATA_DIR` wins over the configuration file, which is what makes this
  module testable: a test that writes `instances.json` into the developer's
  real `~/.candil` is a test nobody runs twice.
  """
  @spec data_dir() :: binary()
  def data_dir do
    case System.get_env("CANDIL_DATA_DIR") do
      nil -> configured_or_default()
      dir -> Path.expand(dir)
    end
  end

  defp configured_or_default do
    with {:ok, config} <- Candil.Config.File.load(),
         %{"general" => %{"data_dir" => dir}} <- config do
      Path.expand(dir)
    else
      _ -> Path.expand("~/.candil")
    end
  end

  @doc """
  Where Candil keeps its logs.

  `general.log_dir` in the configuration file wins; without it the logs live
  under the data directory, so `CANDIL_DATA_DIR` moves them too.

  This was a key the schema validated, the sample TOML declared, and **no code
  read**: `general.log_dir` passed validation and then went straight to
  nothing, and `--fix` created `<data_dir>/logs` whatever the file said. A
  configurable route that nothing honours is worse than a fixed one, because
  the file is where someone goes looking for the answer.
  """
  @spec log_dir() :: binary()
  def log_dir do
    with {:ok, config} <- Candil.Config.File.load(),
         %{"general" => %{"log_dir" => dir}} <- config do
      Path.expand(dir)
    else
      _ -> Path.join(data_dir(), "logs")
    end
  end

  @doc """
  The run directory, created if it is not there.
  """
  @spec run_dir() :: binary()
  def run_dir do
    dir = Path.join(data_dir(), "run")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  The full path of `instances.json`.
  """
  @spec path() :: binary()
  def path, do: Path.join(run_dir(), "instances.json")

  @doc """
  Every running instance, with dead ones pruned on the way out.

  A missing file is an empty list, not an error: nothing has ever been started
  and that is a perfectly good answer.
  """
  @spec read() :: [instance()]
  def read do
    case File.read(path()) do
      {:ok, ""} -> []
      {:ok, contents} -> decode(contents) |> Enum.filter(&alive?/1)
      {:error, _} -> []
    end
  end

  @doc """
  Rewrites the file with `instances`, atomically.
  """
  @spec write([instance()]) :: :ok | {:error, File.posix()}
  def write(instances) do
    target = path()
    temp = target <> ".tmp"

    case File.write(temp, Jason.encode!(instances)) do
      :ok -> File.rename(temp, target)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replaces the entry for `{model, port}`, or removes it when given `nil`.

  Keyed by the pair, not by the model alone: the same model can be alive on a
  GPU port and a CPU port at the same time, and that is the case `--cpu`
  exists for.
  """
  @spec put({binary(), pos_integer()}, instance() | nil) :: :ok | {:error, File.posix()}
  def put({_model, _port} = key, nil), do: delete(key)

  def put(key, instance) do
    kept = Enum.reject(read(), &same_key?(&1, key))
    write([instance | kept])
  end

  @doc """
  Removes the entry at `key` if it is there.
  """
  @spec delete({binary(), pos_integer()}) :: :ok | {:error, File.posix()}
  def delete(key) do
    write(Enum.reject(read(), &same_key?(&1, key)))
  end

  @doc """
  Every instance of one model, across all of its ports.
  """
  @spec find(binary()) :: [instance()]
  def find(model), do: Enum.filter(read(), &(&1.model == to_string(model)))

  defp same_key?(%{model: m, port: p}, {m, p}), do: true
  defp same_key?(_, _), do: false

  @doc """
  Whether the owning process is still there.

  The check is the operating system's, not this VM's. The owner of a detached
  instance is a different OS process; asking `Candil.EnginePool` about it would
  always say "no" and every detached instance would be pruned the moment it was
  written.

  `Process.alive?/1` is **not** the answer here, whatever it looks like. It
  takes an Erlang pid or port, not an OS pid, and given an integer it answers
  about an unrelated thing. That is the kind of line that passes a test
  because the test compares the same wrong answer.
  """
  @spec alive?(instance()) :: boolean()
  def alive?(%{pid: pid}) when is_integer(pid) and pid > 0, do: os_alive?(pid)
  def alive?(_), do: false

  # On Linux /proc answers, and it also answers the question `kill -0` cannot:
  # a zombie still exists, still takes a pid, and is exactly the case that has
  # to be pruned. On macOS there is no /proc, and `kill -0` is the portable
  # "can I signal it" probe.
  defp os_alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        fields = String.split(stat, " ")
        state = Enum.at(fields, 2)
        state != nil and state != "Z"

      {:error, :enoent} ->
        false

      {:error, _} ->
        signal_zero(pid)
    end
  end

  defp signal_zero(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  @doc """
  Records a port given explicitly with `--port`, so the next auto-claim can
  avoid it.

  The pool is per-VM. A port that a previous run pinned down has to survive
  that VM, and a list of lines is the smallest thing that does.
  """
  @spec claim_ad_hoc(pos_integer()) :: :ok
  def claim_ad_hoc(port) do
    ports = ad_hoc_ports()

    if port in ports do
      :ok
    else
      lines = Enum.map_join(ports ++ [port], "\n", &Integer.to_string/1)
      File.write(ad_hoc_path(), lines <> "\n")
    end
  end

  @doc """
  Every port that was ever given explicitly, newest last.
  """
  @spec ad_hoc_ports() :: [pos_integer()]
  def ad_hoc_ports do
    case File.read(ad_hoc_path()) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer/1)

      {:error, _} ->
        []
    end
  end

  defp ad_hoc_path, do: Path.join(run_dir(), "ad-hoc-ports")

  @doc """
  The OS pid of this VM, as an integer.

  `System.pid/0` answers a binary on OTP 28, a charlist on some older
  versions and an integer on others. Callers want an integer because a pid
  that goes into JSON as a string fails every `is_integer/1` check on the way
  back in.
  """
  @spec os_pid() :: pos_integer() | nil
  def os_pid, do: normalize_pid(System.pid())

  @doc """
  Builds an instance record from a running engine.
  """
  @spec build(binary(), pos_integer(), binary() | nil, pos_integer() | nil, boolean()) ::
          instance()
  def build(model, port, engine, os_pid, healthy) do
    # `System.pid/0` answers a charlist on some OTP versions and an integer on
    # others, and Jason encodes a charlist as a JSON *string*. A pid written as
    # `"9742"` fails every `is_integer/1` check on the way back in, so the
    # instance reads back as invalid and gets pruned while it is still running.
    os_pid = normalize_pid(os_pid)

    %{
      model: to_string(model),
      port: port,
      engine: engine && to_string(engine),
      pid: os_pid,
      owner: %{kind: :pid, pid: os_pid || 0},
      started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      healthy: healthy
    }
  end

  # Three shapes, not two. `System.pid/0` answers an integer on some OTP
  # versions, a charlist on others, and a BINARY on OTP 28. Handling only the
  # two you expect writes a pid as a JSON string, and every `is_integer/1`
  # check on the way back in rejects it — so the instance prunes itself while
  # it is still running. Catch all three and give up cleanly on the rest.
  defp normalize_pid(pid) when is_integer(pid), do: pid
  defp normalize_pid(pid) when is_binary(pid), do: parse_pid(pid)
  defp normalize_pid(pid) when is_list(pid), do: parse_pid(List.to_string(pid))
  defp normalize_pid(_), do: nil

  defp parse_pid(text) do
    case Integer.parse(text) do
      {pid, ""} -> pid
      _ -> nil
    end
  end

  # `Enum.map/2` + `Enum.reject/2`, NOT `Enum.filter/2` with a function that
  # builds the struct.
  #
  # `Enum.filter/2` returns the ORIGINAL elements when the function answers
  # truthy — it throws away what the function returned. So filtering with a
  # constructor looks like it works, returns the right count, and hands back
  # maps that still have string keys. Everything downstream then misses,
  # silently, and `read/0` answers [] for a file it just wrote itself.
  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&to_instance/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp to_instance(%{"model" => _, "port" => _, "owner" => _} = raw) do
    %{
      model: raw["model"],
      port: raw["port"],
      engine: raw["engine"],
      pid: raw["pid"],
      owner: owner(raw["owner"]),
      started_at: raw["started_at"] || "",
      healthy: raw["healthy"] == true
    }
  end

  defp to_instance(_), do: nil

  # A record with a pid of 0 is not an instance Candil can stop. It comes back
  # as nil and `alive?/1` says no, which is the answer.
  defp owner(%{"kind" => "pid", "pid" => pid}) when is_integer(pid) and pid > 0,
    do: %{kind: :pid, pid: pid}

  defp owner(_), do: %{kind: :pid, pid: 0}
end
