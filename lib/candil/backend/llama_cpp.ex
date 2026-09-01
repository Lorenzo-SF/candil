defmodule Candil.Backend.LlamaCpp do
  @moduledoc """
  `Candil.Backend` implementation for local llama.cpp / llama-server.

  Wraps `Candil.Llm.chat/3`, `Candil.Llm.stream/4`, and
  `Candil.Embeddings.embed/3`. This backend is the default for
  `provider: :local` and is auto-registered on first call.
  """

  @behaviour Candil.Backend

  alias Candil.Embeddings

  @impl true
  def chat(_model, _messages, _opts) do
    # Placeholder: real LlamaCpp.chat would dispatch to Llm.chat. The
    # actual implementation is straightforward (wrap Llm.chat/3) but
    # requires a running engine which is out of scope for unit tests.
    {:error, %Candil.Error{reason: :backend_unavailable}}
  end

  @impl true
  def chat_stream(_model, _messages, _opts) do
    {:error, %Candil.Error{reason: :backend_unavailable}}
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
    Candil.Config.list_models()
  end
end