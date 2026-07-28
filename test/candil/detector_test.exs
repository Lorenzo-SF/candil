defmodule Candil.DetectorTest do
  use ExUnit.Case, async: false

  import Mox

  alias Apero.Http.{Request, Response}
  alias Candil.{Detector, HTTPAdapterMock}

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
end
