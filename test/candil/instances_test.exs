defmodule Candil.InstancesTest do
  use ExUnit.Case, async: false

  alias Candil.Instances

  setup do
    dir = Path.join(System.tmp_dir!(), "candil-inst-#{System.unique_integer([:positive])}")
    previous = System.get_env("CANDIL_DATA_DIR")
    System.put_env("CANDIL_DATA_DIR", dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: System.put_env("CANDIL_DATA_DIR", previous)
    end)

    :ok
  end

  # A pid that is certainly not running. 2^22 is above the default pid_max on
  # Linux and macOS, so the kernel has never heard of it.
  @dead 4_194_303

  defp live, do: Instances.build("coder", 9999, "llama_cpp", System.pid(), true)
  defp dead(port \\ 9998), do: Instances.build("coder", port, "llama_cpp", @dead, false)

  describe "writing and reading" do
    test "an instance written is an instance read back" do
      :ok = Instances.put({"coder", 9999}, live())

      assert [instance] = Instances.read()
      assert instance.model == "coder"
      assert instance.port == 9999
      assert instance.engine == "llama_cpp"
      assert instance.owner == %{kind: :pid, pid: instance.pid}
    end

    test "a missing file is an empty catalogue, not an error" do
      refute File.exists?(Instances.path())
      assert [] == Instances.read()
    end

    test "the file is valid JSON a second process could read" do
      :ok = Instances.put({"coder", 9999}, live())

      assert {:ok, [%{"model" => "coder", "owner" => %{"kind" => "pid"}}]} =
               Instances.path() |> File.read!() |> Jason.decode()
    end

    test "the pid is written as a number, not as a string" do
      :ok = Instances.put({"coder", 9999}, live())

      {:ok, [%{"pid" => pid}]} = Instances.path() |> File.read!() |> Jason.decode()
      # `System.pid/0` answers an integer, a charlist or a binary depending on
      # the OTP version, and Jason writes a charlist as a JSON string. A pid
      # stored as `"9742"` fails every is_integer/1 check on the way back in
      # and the instance prunes itself while it is still running.
      assert is_integer(pid)
    end
  end

  describe "pruning" do
    test "an instance whose owner is gone is not reported as running" do
      :ok = Instances.put({"coder", 9998}, dead())
      :ok = Instances.put({"coder", 9999}, live())

      assert [instance] = Instances.read()
      assert instance.port == 9999
    end

    test "the file is left with the dead entry until something rewrites it" do
      # read/0 prunes on the way out; it does not rewrite behind your back.
      # A read that mutates the file is a read you cannot do twice.
      :ok = Instances.put({"coder", 9998}, dead())
      assert [] == Instances.read()

      raw = Instances.path() |> File.read!() |> Jason.decode!()
      assert length(raw) == 1
    end

    test "a record that is not a valid instance is skipped" do
      File.mkdir_p!(Instances.run_dir())
      File.write!(Instances.path(), Jason.encode!([%{"nope" => true}]))

      assert [] == Instances.read()
    end

    test "a truncated file is an empty catalogue, not a crash" do
      File.mkdir_p!(Instances.run_dir())
      File.write!(Instances.path(), "[{\"model\": \"cod")

      assert [] == Instances.read()
    end
  end

  describe "the pair, not the model" do
    test "the same model on two ports is two instances" do
      # This is the case `--cpu` exists for: a GPU slot and a CPU slot at once.
      :ok = Instances.put({"coder", 9999}, live())
      :ok = Instances.put({"coder", 9998}, %{live() | port: 9998})

      assert [9998, 9999] == Instances.find("coder") |> Enum.map(& &1.port) |> Enum.sort()
    end

    test "put replaces only its own key" do
      :ok = Instances.put({"coder", 9999}, live())
      :ok = Instances.put({"coder", 9998}, %{live() | port: 9998, engine: "otro"})
      :ok = Instances.put({"coder", 9999}, %{live() | engine: "cambiado"})

      by_port = Map.new(Instances.read(), &{&1.port, &1.engine})
      assert by_port[9999] == "cambiado"
      assert by_port[9998] == "otro"
    end

    test "delete removes one and leaves the other" do
      :ok = Instances.put({"coder", 9999}, live())
      :ok = Instances.put({"coder", 9998}, %{live() | port: 9998})

      :ok = Instances.delete({"coder", 9999})

      assert [9998] == Instances.find("coder") |> Enum.map(& &1.port)
    end
  end

  describe "ad-hoc ports" do
    test "a port given explicitly is remembered across VMs" do
      :ok = Instances.claim_ad_hoc(10_500)

      assert [10_500] == Instances.ad_hoc_ports()
    end

    test "claiming twice does not duplicate it" do
      :ok = Instances.claim_ad_hoc(10_500)
      :ok = Instances.claim_ad_hoc(10_500)

      assert [10_500] == Instances.ad_hoc_ports()
    end

    test "an empty list before anything was claimed" do
      assert [] == Instances.ad_hoc_ports()
    end
  end

  describe "data_dir" do
    test "CANDIL_DATA_DIR wins, which is what makes this module testable" do
      # A test that wrote into the developer's real ~/.candil is a test
      # nobody runs twice.
      assert Instances.data_dir() == System.get_env("CANDIL_DATA_DIR")
    end
  end
end
