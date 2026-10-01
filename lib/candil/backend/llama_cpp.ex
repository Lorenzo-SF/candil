defmodule Candil.Backend.LlamaCpp do
  @moduledoc """
  `Candil.Backend` implementation for local llama.cpp / llama-server.

  Wraps the local inference path. This backend is the default for
  `provider: :local` and is auto-registered on first call.
  """

  @behaviour Candil.Backend

  alias Candil.{Backend, Embeddings, Inference, Model, Store, Stream}

  @impl true
  def chat(model, messages, opts) when is_list(messages) do
    with {:ok, alias_} <- resolve(model) do
      Inference.chat_local(alias_, messages, opts)
    end
  end

  @impl true
  def chat_stream(model, messages, opts) when is_list(messages) do
    with {:ok, alias_} <- resolve(model) do
      Stream.chat(alias_, messages, opts)
    end
  end

  @impl true
  def embed(_model, texts, opts) when is_list(texts) do
    case Embeddings.embed_batch(texts, opts) do
      {:ok, vectors} -> {:ok, vectors}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def models do
    Store.list_models()
  end

  # The behaviour accepts a model struct or an alias, and a string alias is
  # legal everywhere a binary name is. `String.to_existing_atom/1` rather than
  # `String.to_atom/1`: the atom table is finite and this value can arrive
  # from a gateway request body.
  defp resolve(%Model{alias: alias_}), do: {:ok, alias_}
  defp resolve(alias_) when is_atom(alias_), do: {:ok, alias_}

  defp resolve(alias_) when is_binary(alias_) do
    String.to_existing_atom(alias_)
  rescue
    ArgumentError -> {:error, Backend.backend_unavailable(:local, alias_)}
  end

  defp resolve(other) do
    {:error, Backend.backend_unavailable(:local, other)}
  end
end
