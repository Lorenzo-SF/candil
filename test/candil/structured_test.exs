defmodule Candil.StructuredTest do
  use ExUnit.Case, async: false

  alias Candil.{Backend, Structured}

  defmodule FakeBackend do
    @behaviour Candil.Backend

    @impl true
    def chat(_model, _messages, opts) do
      case Keyword.get(opts, :test_response, :valid) do
        :valid ->
          {:ok,
           %{
             content: ~s({"title": "Dune", "year": 1965}),
             finish_reason: "stop",
             usage: %{input_tokens: 0, output_tokens: 0}
           }}

        :invalid ->
          {:ok,
           %{
             content: "not json at all",
             finish_reason: "stop",
             usage: %{input_tokens: 0, output_tokens: 0}
           }}
      end
    end

    @impl true
    def chat_stream(_, _, _), do: {:ok, []}
    @impl true
    def embed(_, _, _), do: {:ok, []}
    @impl true
    def models, do: []
  end

  defmodule FencedBackend do
    @behaviour Candil.Backend

    @impl true
    def chat(_, _, _) do
      {:ok,
       %{
         content: "```json\n{\"ok\": true}\n```",
         finish_reason: "stop",
         usage: %{input_tokens: 0, output_tokens: 0}
       }}
    end

    @impl true
    def chat_stream(_, _, _), do: {:ok, []}
    @impl true
    def embed(_, _, _), do: {:ok, []}
    @impl true
    def models, do: []
  end

  setup do
    Backend.register(:fake, FakeBackend)
    Backend.register(:fenced, FencedBackend)
    :ok
  end

  test "complete/4 returns parsed map on valid JSON" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "year" => %{"type" => "integer"}
      },
      "required" => ["title", "year"]
    }

    assert {:ok, %{"title" => "Dune", "year" => 1965}} =
             Structured.complete("fake-model", "Recommend a book", schema,
               backend: FakeBackend,
               max_retries: 0
             )
  end

  test "complete/4 retries on invalid JSON then fails after max_retries" do
    schema = %{"required" => ["title"]}

    assert {:error, %Candil.Error{reason: :invalid_request}} =
             Structured.complete("fake-model", "Bad", schema,
               backend: FakeBackend,
               max_retries: 1,
               test_response: :invalid
             )
  end

  test "complete/4 tolerates markdown code fences in response" do
    schema = %{"required" => ["ok"]}

    assert {:ok, %{"ok" => true}} =
             Structured.complete("any", "hi", schema,
               backend: FencedBackend,
               max_retries: 0
             )
  end
end