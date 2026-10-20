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

    test "size_mb 0 procede sin mirar dispositivos (modelo de CPU)" do
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 0, usable: true}]
      assert Scheduler.place(0, devices, []) == {:ok, :proceed}
      assert Scheduler.place(0, [], []) == {:ok, :proceed}
    end

    test "la decisión de expulsión con los números de la máquina, en CI" do
      # Los números medidos: visión ocupa 7_472 MB de una GPU de 16_303, así
      # que quedan 9_429 libres; un modelo de 10_000 no cabe y la víctima
      # barata es visión. Este test es la mitad que NO necesita la máquina:
      # fija la decisión, no la ejecución.
      devices = [%{index: 0, name: "RTX 5080", total_mb: 16_303, free_mb: 9_429, usable: true}]

      instances = [
        %{
          model_alias: :vision,
          device_index: 0,
          size_mb: 7_472,
          in_use: false,
          pinned: false,
          last_used_at: nil
        }
      ]

      assert Scheduler.place(10_000, devices, instances) == {:evict, [:vision], 0}
    end

    test "no expulsa una instancia cuyo device_index es nil" do
      # `nil` es «no sé en qué GPU está» (modelo en CPU, o sin nvidia-smi).
      # No se puede expulsar lo que no se sabe que ocupa la GPU: liberaría
      # cero megas y el plan diría que hay sitio donde no lo hay.
      devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 1_000, usable: true}]

      instances = [
        %{
          model_alias: :en_cpu,
          device_index: nil,
          size_mb: 8_000,
          in_use: false,
          pinned: false,
          last_used_at: nil
        }
      ]

      assert Scheduler.place(4_000, devices, instances) == {:error, :no_room}
    end
  end

  describe "device_index/2" do
    test "sale del PID medido, no del puerto" do
      usage = %{1_234 => %{pid: 1_234, device_index: 1, used_mb: 8_000}}
      assert Scheduler.device_index(1_234, usage) == 1
    end

    test "un PID sin medición es nil, no 0" do
      # Un modelo de CPU no aparece en nvidia-smi, y sin nvidia-smi no hay
      # medición. Los dos casos son «no lo sé», y el scheduler no los trata
      # como device 0.
      assert Scheduler.device_index(9_999, %{}) == nil
      assert Scheduler.device_index(nil, %{}) == nil
    end
  end
end
