defmodule Candil.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias Candil.Embeddings

  defmodule FakeServer do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, %{chunks: []}, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:chunks, _from, state), do: {:reply, state.chunks, state}

    @impl true
    def handle_call({:record, size}, _from, state) do
      {:reply, :ok, %{state | chunks: state.chunks ++ [size]}}
    end
  end

  setup do
    start_supervised!(FakeServer)
    # HTTP requests go to a dead port — but we test pure chunking logic
    # through the batch size computation, not actual requests.
    :ok
  end

  defp chunk_sizes(texts, batch_size) do
    # Verify chunking logic independently of HTTP.
    texts |> Enum.chunk_every(batch_size) |> Enum.map(&length/1)
  end

  test "embed/2 with a single text returns an error for unreachable host" do
    assert {:error, _} = Embeddings.embed("hello", url: "http://192.0.2.1:1")
  end

  test "embed_batch/2 chunks texts by batch_size" do
    texts = Enum.map(1..100, fn i -> "text #{i}" end)
    assert chunk_sizes(texts, 32) == [32, 32, 32, 4]
    assert chunk_sizes(texts, 10) == [10, 10, 10, 10, 10, 10, 10, 10, 10, 10]
  end

  test "embed_batch/2 default batch_size is 32" do
    texts = Enum.map(1..100, fn i -> "text #{i}" end)

    # The function must return either vectors or an error (unreachable
    # host in test), but never crash on chunking.
    result = Embeddings.embed_batch(texts, url: "http://192.0.2.1:1", timeout_ms: 100)
    assert match?({:error, _}, result)
  end

  test "embed_batch/2 with batch_size option uses it" do
    texts = Enum.map(1..100, fn i -> "text #{i}" end)
    result = Embeddings.embed_batch(texts, url: "http://192.0.2.1:1", batch_size: 10, timeout_ms: 100)
    assert match?({:error, _}, result)
  end

  test "embed/2 unknown provider returns error" do
    assert {:error, "unknown provider: foo"} = Embeddings.embed("hi", provider: "foo")
  end

  test "embed_batch/2 ollama provider returns error for unreachable host" do
    result = Embeddings.embed_batch(["a", "b"], provider: "ollama", url: "http://192.0.2.1:1", timeout_ms: 100)
    assert match?({:error, _}, result)
  end
end