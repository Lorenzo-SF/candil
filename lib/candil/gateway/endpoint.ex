defmodule Candil.Gateway.Endpoint do
  @moduledoc """
  The gateway's route table.

  Kept as data rather than as a Plug pipeline for now: the handlers land in
  phase 8, and a route table that exists and is tested is worth more at this
  point than a pipeline that returns 501. `routes/0` is what the start banner
  prints and what the handler tests iterate over, so the contract is already
  pinned before the bodies exist.
  """

  @type route :: %{
          method: String.t(),
          path: String.t(),
          handler: atom(),
          consumer: :required | :default
        }

  @routes [
    %{
      method: "POST",
      path: "/c/:consumer/v1/chat/completions",
      handler: Candil.Gateway.Handlers.ChatCompletions,
      consumer: :required
    },
    %{
      method: "POST",
      path: "/c/:consumer/v1/messages",
      handler: Candil.Gateway.Handlers.Messages,
      consumer: :required
    },
    %{
      method: "POST",
      path: "/c/:consumer/v1/embeddings",
      handler: Candil.Gateway.Handlers.Embeddings,
      consumer: :required
    },
    %{
      method: "GET",
      path: "/c/:consumer/v1/models",
      handler: Candil.Gateway.Handlers.Models,
      consumer: :required
    },
    %{
      method: "POST",
      path: "/v1/chat/completions",
      handler: Candil.Gateway.Handlers.ChatCompletions,
      consumer: :default
    },
    %{
      method: "POST",
      path: "/v1/messages",
      handler: Candil.Gateway.Handlers.Messages,
      consumer: :default
    },
    %{
      method: "POST",
      path: "/v1/embeddings",
      handler: Candil.Gateway.Handlers.Embeddings,
      consumer: :default
    },
    %{
      method: "GET",
      path: "/v1/models",
      handler: Candil.Gateway.Handlers.Models,
      consumer: :default
    },
    %{method: "GET", path: "/health", handler: Candil.Gateway.Handlers.Health, consumer: :none},
    %{method: "GET", path: "/metrics", handler: Candil.Gateway.Handlers.Metrics, consumer: :none}
  ]

  @doc """
  Every route the gateway serves.
  """
  @spec routes() :: [route()]
  def routes, do: @routes

  @doc """
  The route table as `{path, methods}` pairs, for the start banner.
  """
  @spec summary() :: [{String.t(), [String.t()]}]
  def summary do
    @routes
    |> Enum.group_by(& &1.path, & &1.method)
    |> Enum.map(fn {path, methods} -> {path, methods} end)
  end

  @doc """
  The handler for a method and path, or `:error`.

  Matching is exact. A gateway that silently accepts `/v1/chat/completions/`
  with a trailing slash, and `/v1/chat/completion` without the s, is a
  gateway that answers differently on two days for the same client.
  """
  @spec match(String.t(), String.t()) :: {:ok, route()} | :error
  def match(method, path) do
    Enum.find(@routes, fn route ->
      route.method == method and route.path == path
    end)
    |> case do
      nil -> :error
      route -> {:ok, route}
    end
  end

  @doc """
  The consumer for a request, or an error when the route needs one and it is
  missing.
  """
  @spec consumer(route(), binary() | nil, atom()) ::
          {:ok, atom()} | {:error, :missing_consumer}
  def consumer(%{consumer: :none}, _from_path, fallback), do: {:ok, fallback}
  def consumer(%{consumer: :default}, _from_path, fallback), do: {:ok, fallback}

  def consumer(%{consumer: :required}, nil, _fallback), do: {:error, :missing_consumer}

  def consumer(%{consumer: :required}, name, _fallback) do
    # Never String.to_atom/1 on a name from the URL. The atom table is finite
    # and never shrinks, so an endpoint that converts whatever arrives is an
    # endpoint that can be made to leak memory at a byte per request. A
    # consumer that exists was defined in the config file, and the config
    # file already made its atom.
    # to_existing_atom/1 raises rather than returning a tagged error.
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, {:unknown_consumer, name}}
  end
end
