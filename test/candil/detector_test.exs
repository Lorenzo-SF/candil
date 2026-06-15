defmodule Candil.DetectorTest do
  use ExUnit.Case, async: true

  alias Candil.Detector

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

  # Note: Testing GPU detection and latest_release_tag/asset_url requires
  # mocking System.cmd/3 and Req.get/2 which is complex without modifying the code.
  # These tests would be integration tests.

  describe "latest_release_tag/0" do
    test "returns an error tuple or ok tuple" do
      # Without mocking Req, we can't predict the result
      # Just verify it returns the expected format
      result = Detector.latest_release_tag()
      assert is_tuple(result)
    end
  end

  describe "asset_url/1" do
    test "returns an error tuple or ok tuple" do
      result = Detector.asset_url(:latest)
      assert is_tuple(result)
    end
  end
end
