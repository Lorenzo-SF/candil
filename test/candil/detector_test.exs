defmodule Candil.DetectorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Apero.Http.{Request, Response}
  alias Candil.{Detector, HTTPAdapterMock}
  alias Candil.Detector.Models
  alias Trebejo.OS

  setup :verify_on_exit!

  setup do
    previous_adapter = Application.get_env(:apero, :http_adapter)
    Application.put_env(:apero, :http_adapter, HTTPAdapterMock)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:apero, :http_adapter, previous_adapter)
      else
        Application.delete_env(:apero, :http_adapter)
      end
    end)

    :ok
  end

  describe "detect/0" do
    test "returns a detection map with required keys" do
      detection = Detector.detect()

      assert is_map(detection)
      assert Map.has_key?(detection, :os)
      assert Map.has_key?(detection, :arch)
      assert Map.has_key?(detection, :gpu)
      assert Map.has_key?(detection, :cuda_version)
      assert Map.has_key?(detection, :asset_pattern)
    end

    test "asset_pattern is a binary string" do
      detection = Detector.detect()
      assert is_binary(detection.asset_pattern)
      assert detection.asset_pattern != ""
    end

    test "gpu is one of the valid backends" do
      detection = Detector.detect()
      assert detection.gpu in [:cuda, :rocm, :metal, :vulkan, :sycl, :cpu]
    end
  end

  describe "latest_release_tag/0" do
    test "returns the latest release tag" do
      expect(HTTPAdapterMock, :request, fn %Request{method: :get, url: url} ->
        assert String.ends_with?(url, "/latest")
        {:ok, %Response{status: 200, headers: [], body: %{"tag_name" => "b123"}}}
      end)

      assert {:ok, "b123"} = Detector.latest_release_tag()
    end
  end

  describe "asset_url/1" do
    test "resolves the matching asset from the latest release" do
      pattern = Detector.detect().asset_pattern
      download_url = "https://example.test/llama-b123.zip"

      expect(HTTPAdapterMock, :request, 2, fn %Request{method: :get, url: url} ->
        if String.ends_with?(url, "/latest") do
          {:ok, %Response{status: 200, headers: [], body: %{"tag_name" => "b123"}}}
        else
          body = %{
            "assets" => [
              %{
                "name" => "llama-b123-#{pattern}.zip",
                "browser_download_url" => download_url
              }
            ]
          }

          {:ok, %Response{status: 200, headers: [], body: body}}
        end
      end)

      assert {:ok, ^download_url} = Detector.asset_url(:latest)
    end
  end

  # B6. A missing Trebejo used to turn into a bare `:unknown`, and the
  # precompiled binary was then chosen from it and failed three layers later
  # with nothing connecting the two. The shape of `detect/0` did not change —
  # callers depend on it — but the reason now travels with it and is logged.

  describe "safe_arch/0" do
    test "returns a tagged tuple, never a bare value" do
      # The contract is the shape, not the answer: whichever way it goes, the
      # caller is told which one it is.
      case Detector.safe_arch() do
        {:ok, arch} -> assert is_atom(arch)
        {:error, :trebejo_not_available} -> :ok
      end
    end

    test "agrees with Trebejo when Trebejo is there" do
      # "Trebejo is there" and "Trebejo knows the architecture" are two
      # different facts and only the second can be an `{:ok, _}`: `arch/0` has
      # `:unknown` in its own return type, and that is what it answers when it
      # could not read it. Asserting `{:ok, _}` unconditionally made this test
      # contradict the frozen one below, which says `:unknown` means
      # `:trebejo_not_available`. Only one of the pair could ever pass; this
      # one was the wrong half.
      case OS.arch() do
        :unknown -> assert Detector.safe_arch() == {:error, :trebejo_not_available}
        arch -> assert {:ok, ^arch} = Detector.safe_arch()
      end
    end

    test "is public, so a caller can ask before downloading anything" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Detector} = Code.ensure_loaded(Detector)
      assert function_exported?(Detector, :safe_arch, 0)
    end
  end

  describe "detect/0 when the architecture cannot be read" do
    test "carries the reason instead of hiding it" do
      detection = Detector.detect()

      if detection.arch == :unknown do
        assert detection.arch_error == :trebejo_not_available
      else
        assert detection.arch_error == nil
      end
    end

    test "logs a warning that names the problem" do
      log =
        capture_log(fn ->
          send(self(), {:detection, Detector.detect()})
        end)

      assert_received {:detection, detection}

      if detection.arch_error do
        assert log =~ "trebejo_not_available"
        assert log =~ ":unknown"
      else
        refute log =~ "trebejo_not_available"
      end
    end

    test "still builds an asset pattern, degraded or not" do
      detection = Detector.detect()
      assert is_binary(detection.asset_pattern)
      assert detection.asset_pattern != ""
    end
  end

  # Found by running the real API, not by reading it. `releases/latest` for
  # llama.cpp is a version tag with no binaries in it, and the old fallback
  # answered that by handing back a Windows CUDA zip — on Linux.

  describe "find_matching_asset/2 against the real shape of a release" do
    @real_release [
      %{
        "name" => "cudart-llama-bin-win-cuda-12.4-x64.zip",
        "browser_download_url" => "https://example.test/WIN.zip"
      },
      %{
        "name" => "llama-b11327-bin-ubuntu-x64.zip",
        "browser_download_url" => "https://example.test/UBUNTU.zip"
      },
      %{
        "name" => "llama-b11327-bin-macos-arm64.zip",
        "browser_download_url" => "https://example.test/MAC.zip"
      }
    ]

    @empty_release [
      %{"name" => "nightly-tag.txt", "browser_download_url" => "https://example.test/x"}
    ]

    test "returns the asset that matches, when there is one" do
      assert {:ok, "https://example.test/UBUNTU.zip"} =
               Models.find_matching_asset(@real_release, "bin-ubuntu-x64")
    end

    test "refuses rather than offering a binary for another platform" do
      # The one that used to be a Windows CUDA zip. Downloading it on Linux
      # works, unpacking it works, and running it does not.
      assert {:error, {:no_such_platform, "bin-linux-riscv64"}} =
               Models.find_matching_asset(@real_release, "bin-linux-riscv64")
    end

    test "says the release has no binaries at all, separately" do
      # `:latest` for llama.cpp lands here, and the two are different problems.
      assert {:error, :no_matching_asset} =
               Models.find_matching_asset(@empty_release, "bin-ubuntu-x64")
    end
  end
end
