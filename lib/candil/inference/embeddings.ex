defmodule Candil.Inference.Embeddings do
  @moduledoc false

  alias Candil.{Engine, Error, HTTP, Model, Provider}

  def do_embed_local(model_alias, texts) do
    case Engine.base_url(model_alias) do
      nil ->
        {:error, Error.engine_not_running(model_alias)}

      base_url ->
        body = %{input: texts}

        HTTP.post_json("#{base_url}/v1/embeddings", body, [], [])
        |> parse_embeddings_response()
    end
  end

  def do_embed_remote(%Model{} = model, %Provider{type: :ollama} = provider, texts, _opts) do
    headers = Provider.auth_headers(provider)

    results =
      Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
        body = %{model: model.name, prompt: text}

        case HTTP.post_json(Provider.embeddings_url(provider), body, headers, [])
             |> parse_ollama_embedding() do
          {:ok, embedding} -> {:cont, {:ok, [embedding | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case results do
      {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
      err -> err
    end
  end

  def do_embed_remote(%Model{} = model, %Provider{} = provider, texts, _opts) do
    headers = Provider.auth_headers(provider)
    body = %{model: model.name, input: texts}

    HTTP.post_json(Provider.embeddings_url(provider), body, headers, [])
    |> parse_embeddings_response()
  end

  defp parse_embeddings_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    embeddings =
      body
      |> Map.get("data", [])
      |> Enum.map(& &1["embedding"])

    {:ok, embeddings}
  end

  defp parse_embeddings_response({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, inspect(body))}
  end

  defp parse_embeddings_response({:error, reason}), do: {:error, reason}

  defp parse_ollama_embedding({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body["embedding"] || []}
  end

  defp parse_ollama_embedding({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, inspect(body))}
  end

  defp parse_ollama_embedding({:error, reason}), do: {:error, reason}
end
