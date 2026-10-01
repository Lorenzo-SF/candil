defmodule Candil.DetectorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Apero.Http.{Request, Response}
  alias Candil.{Detector, HTTPAdapterMock}
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
      assert {:ok, arch} = Detector.safe_arch()
      assert arch == OS.arch()
    end

    test "is public, so a caller can ask before downloading anything" do
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
end
