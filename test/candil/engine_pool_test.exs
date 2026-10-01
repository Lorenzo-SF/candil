defmodule Candil.EnginePoolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Candil.{Engine, EnginePool, Model}

  @loopback {127, 0, 0, 1}

  setup do
    # The registry is application state and the supervisor starts it for every
    # test run, so it has to be emptied rather than assumed empty.
    Enum.each(EnginePool.list(), fn instance ->
      :ok = EnginePool.delete(instance.alias, instance.port)
    end)

    :ok
  end

  defp model(alias), do: %Model{alias: alias, type: :local, engine: :llama_cpp}
  defp engine, do: %Engine{alias: :llama_cpp}

  describe "put/5 and get/2" do
    test "registers an instance under the alias and port" do
      assert :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())

      assert {:ok, instance} = EnginePool.get(:coder, 9999)
      assert instance.alias == :coder
      assert instance.port == 9999
      assert instance.pid == self()
      assert instance.model.alias == :coder
      assert instance.engine.alias == :llama_cpp
      assert instance.started_at <= System.monotonic_time(:millisecond)
    end

    test "an unknown key is :error, not a raise and not nil" do
      assert :error = EnginePool.get(:nope, 9999)
    end

    test "the alias alone is not a key" do
      # Same model, two ports: a GPU slot and a CPU slot. This is the case the
      # old alias-keyed LRU could not represent.
      :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())
      :ok = EnginePool.put(:coder, 9998, self(), model(:coder), engine())

      assert {:ok, %{port: 9999}} = EnginePool.get(:coder, 9999)
      assert {:ok, %{port: 9998}} = EnginePool.get(:coder, 9998)
    end

    test "the same port with a different alias is a different instance" do
      :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())
      :ok = EnginePool.put(:analyst, 9999, self(), model(:analyst), engine())

      assert {:ok, %{alias: :coder}} = EnginePool.get(:coder, 9999)
      assert {:ok, %{alias: :analyst}} = EnginePool.get(:analyst, 9999)
      assert EnginePool.count() == 2
    end

    test "put/5 replaces the instance at that key rather than adding a second" do
      :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())
      :ok = EnginePool.put(:coder, 9999, nil, model(:coder), engine())

      assert EnginePool.count() == 1
      assert {:ok, %{pid: nil}} = EnginePool.get(:coder, 9999)
    end

    test "put/5 is a call, so a caller knows the entry is there" do
      # It used to be a cast. A cast answers :ok whether or not anything was
      # stored, which left the caller unable to tell whether the port it just
      # started a server on was the port the next request would use.
      assert :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())
      assert {:ok, _} = EnginePool.get(:coder, 9999)
    end
  end

  describe "delete/2" do
    test "removes exactly that instance" do
      :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())
      :ok = EnginePool.put(:coder, 9998, self(), model(:coder), engine())

      assert :ok = EnginePool.delete(:coder, 9999)
      assert :error = EnginePool.get(:coder, 9999)
      assert {:ok, _} = EnginePool.get(:coder, 9998)
    end

    test "deleting something that was never there is not an error" do
      # The absence is the point of the call. Making it raise would mean a
      # stop path had to know whether a start had ever succeeded.
      assert :ok = EnginePool.delete(:ghost, 1234)
    end
  end

  describe "list/0, count/0, ports/0 and by_model/1" do
    setup do
      :ok = EnginePool.put(:coder, 9999, self(), model(:coder), engine())
      :ok = EnginePool.put(:coder, 9998, self(), model(:coder), engine())
      :ok = EnginePool.put(:analyst, 9997, self(), model(:analyst), engine())
      :ok
    end

    test "list returns every instance" do
      assert length(EnginePool.list()) == 3
    end

    test "count agrees with list" do
      assert EnginePool.count() == length(EnginePool.list())
    end

    test "ports are ascending and deduplicated per instance" do
      assert EnginePool.ports() == [9997, 9998, 9999]
    end

    test "by_model finds every port of one model" do
      assert [9998, 9999] = Enum.map(EnginePool.by_model(:coder), & &1.port)
    end

    test "by_model on something unknown is an empty list" do
      assert [] = EnginePool.by_model(:nobody)
    end

    test "the empty registry says so rather than raising" do
      Enum.each(EnginePool.list(), fn i -> EnginePool.delete(i.alias, i.port) end)

      assert [] = EnginePool.list()
      assert 0 = EnginePool.count()
      assert [] = EnginePool.ports()
    end
  end

  describe "claim_port/2" do
    test "returns a port inside the range it was given" do
      assert {:ok, port} = EnginePool.claim_port(43_000, 43_099)
      assert port in 43_000..43_099
    end

    test "never returns a port this registry already handed out" do
      {:ok, first} = EnginePool.claim_port(43_100, 43_102)
      :ok = EnginePool.put(:coder, first, self(), model(:coder), engine())

      {:ok, second} = EnginePool.claim_port(43_100, 43_102)
      refute second == first
      assert second in 43_100..43_102
    end

    test "skips a port that actually has something listening on it" do
      # This is the case the whole function exists for: a ropero server left
      # holding a socket looks free to every port check except a real connect.
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: @loopback])

      {:ok, held} = :inet.port(listen)
      base = held - 1

      assert {:ok, port} = EnginePool.claim_port(base, held + 2)
      refute port == held, "claimed a port that is plainly listening"
      assert port in base..(held + 2)

      :gen_tcp.close(listen)
    end

    test "a full range is :no_free_port" do
      :ok = EnginePool.put(:a, 43_200, self(), model(:a), engine())
      :ok = EnginePool.put(:b, 43_201, self(), model(:b), engine())

      assert {:error, :no_free_port} = EnginePool.claim_port(43_200, 43_201)
    end

    test "a single-port range either has it or does not" do
      assert {:ok, 43_300} = EnginePool.claim_port(43_300, 43_300)
      :ok = EnginePool.put(:a, 43_300, self(), model(:a), engine())
      assert {:error, :no_free_port} = EnginePool.claim_port(43_300, 43_300)
    end
  end

  describe "get/0" do
    test "is marked deprecated in the documentation" do
      # The contract is the annotation, not the return value: `@deprecated` is
      # what shows a caller at compile time, and a release of warnings nobody
      # reads is not a deprecation.
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Candil.EnginePool)

      entry = Enum.find(docs, &match?({{:function, :get, 0}, _, _, _, _}, &1))
      assert entry, "get/0 is not in the docs at all"

      {{:function, :get, 0}, _arity, _signature, _doc, metadata} = entry
      assert Map.get(metadata, :deprecated) =~ "get/2"
    end

    test "answers :empty rather than an engine" do
      # There is no least-recently-used anything to return. Returning a real
      # engine here would keep the old lie alive at the one place callers were
      # told to stop using.
      capture_io(:stderr, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        assert apply(EnginePool, :get, []) == :empty
      end)
    end
  end
end
