defmodule Candil.SchedulerTest do
  use ExUnit.Case, async: true

  doctest Candil.Scheduler

  alias Candil.Scheduler

  describe "place/3" do
    test "cabe tal cual, sin tocar nada (regla 1)" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 10_000, usable: true}]
      assert Scheduler.place(4_000, devices, []) == {:ok, 0}
    end

    test "no cabe en ninguno y no hay víctima → no_room" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 1_000, usable: true}]

      instances = [
        %{
          model_alias: :coder,
          device_index: 0,
          size_mb: 12_000,
          in_use: true,
          pinned: false,
          last_used_at: nil
        }
      ]

      assert Scheduler.place(4_000, devices, instances) == {:error, :no_room}
    end

    test "expulsa la víctima más barata cuando no cabe" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 1_000, usable: true}]

      instances = [
        %{
          model_alias: :embedder,
          device_index: 0,
          size_mb: 1_800,
          in_use: false,
          pinned: false,
          last_used_at: nil
        }
      ]

      assert Scheduler.place(1_800, devices, instances) == {:evict, [:embedder], 0}
    end

    test "nunca expulsa lo que está en uso" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 1_000, usable: true}]

      instances = [
        %{
          model_alias: :coder,
          device_index: 0,
          size_mb: 12_000,
          in_use: true,
          pinned: false,
          last_used_at: nil
        }
      ]

      assert Scheduler.place(4_000, devices, instances) == {:error, :no_room}
    end

    test "nunca expulsa lo que tiene pin" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 1_000, usable: true}]

      instances = [
        %{
          model_alias: :coder,
          device_index: 0,
          size_mb: 12_000,
          in_use: false,
          pinned: true,
          last_used_at: nil
        }
      ]

      assert Scheduler.place(4_000, devices, instances) == {:error, :no_room}
    end

    test "elige el dispositivo con más espacio libre" do
      devices = [
        %{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 4_000, usable: true},
        %{index: 1, name: "GPU1", total_mb: 16_000, free_mb: 10_000, usable: true}
      ]

      assert Scheduler.place(4_000, devices, []) == {:ok, 1}
    end

    test "ignora dispositivos no usables" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 10_000, usable: false}]
      assert Scheduler.place(4_000, devices, []) == {:error, :no_room}
    end

    test "sin dispositivos, no_room" do
      assert Scheduler.place(4_000, [], []) == {:error, :no_room}
    end

    test "size_mb 0 cabe en cualquier dispositivo usable" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 0, usable: true}]
      assert Scheduler.place(0, devices, []) == {:ok, 0}
    end
  end
end
