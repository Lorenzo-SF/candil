defmodule Candil.Detector.Release do
  @moduledoc false

  alias Apero.Http

  @github_releases_url "https://api.github.com/repos/ggml-org/llama.cpp/releases"

  @spec latest_release_tag() :: {:ok, binary()} | {:error, any()}
  def latest_release_tag do
    url = "#{@github_releases_url}/latest"

    case Http.get(
           url,
           [{"accept", "application/vnd.github+json"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} ->
        {:ok, tag}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Http.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @spec asset_url(:latest | binary()) :: {:ok, binary()} | {:error, any()}
  def asset_url(:latest) do
    case latest_release_tag() do
      {:ok, tag} -> asset_url(tag)
      {:error, reason} -> {:error, reason}
    end
  end

  def asset_url(tag) when is_binary(tag) do
    detection = Candil.Detector.detect()
    url = "#{@github_releases_url}/tags/#{tag}"

    case Http.get(
           url,
           [{"accept", "application/vnd.github+json"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        Candil.Detector.Models.find_matching_asset(assets, detection.asset_pattern)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Http.Error{reason: reason}} ->
        {:error, reason}
    end
  end
end
