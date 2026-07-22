defmodule Candil.Detector.Models do
  @moduledoc false

  def build_asset_pattern(:linux, arch, :cuda, cuda_version) do
    arch_str = arch_string(arch)
    cuda_str = if cuda_version, do: "-#{cuda_version}", else: ""
    "bin-linux-cuda#{cuda_str}-#{arch_str}"
  end

  def build_asset_pattern(:linux, arch, :rocm, _) do
    "bin-linux-rocm-#{arch_string(arch)}"
  end

  def build_asset_pattern(:linux, arch, :vulkan, _) do
    "bin-linux-vulkan-#{arch_string(arch)}"
  end

  def build_asset_pattern(:linux, arch, _, _) do
    "bin-ubuntu-#{arch_string(arch)}"
  end

  def build_asset_pattern(:macos, :arm64, _, _), do: "bin-macos-arm64"
  def build_asset_pattern(:macos, _, _, _), do: "bin-macos-x64"

  def build_asset_pattern(:windows, arch, :cuda, cuda_version) do
    cuda_str = if cuda_version, do: "-#{cuda_version}", else: ""
    "bin-win-cuda#{cuda_str}-#{arch_string(arch)}"
  end

  def build_asset_pattern(:windows, arch, _, _) do
    "bin-win-#{arch_string(arch)}"
  end

  def build_asset_pattern(_, arch, _, _), do: "bin-linux-#{arch_string(arch)}"

  def arch_string(:x86_64), do: "x64"
  def arch_string(:arm64), do: "arm64"
  def arch_string(:arm), do: "arm"
  def arch_string(:i386), do: "x86"
  def arch_string(_), do: "x64"

  def find_matching_asset(assets, pattern) do
    match =
      Enum.find(assets, fn asset ->
        name = Map.get(asset, "name", "")
        String.contains?(name, pattern) and String.ends_with?(name, ".zip")
      end)

    case match do
      nil ->
        fallback = find_fallback_asset(assets)

        if fallback,
          do: {:ok, fallback["browser_download_url"]},
          else: {:error, :no_matching_asset}

      asset ->
        {:ok, asset["browser_download_url"]}
    end
  end

  defp find_fallback_asset(assets) do
    Enum.find(assets, fn asset ->
      name = Map.get(asset, "name", "")

      String.ends_with?(name, ".zip") and
        not String.contains?(name, "src") and
        not String.contains?(name, "sha256")
    end)
  end
end
