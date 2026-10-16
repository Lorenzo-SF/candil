defmodule Candil.Gateway.Endpoint do
  @moduledoc """
  The gateway's route table.

  Kept as data rather than as a Plug pipeline: `routes/0` is what the start
  banner prints, what `Candil.Gateway.Plug` consults to dispatch, and what the
  handler tests iterate over. The route table exists in one place only, and a
  route that is declared but not written answers **501 with a reason** instead
  of a 404 or an empty 500.
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

  Matching is exact **por segmento**, y un segmento declarado `:consumer`
  casa con cualquier uno. Exacta por segmento y no por cadena porque
  `/v1/chat/completions/` con barra final y `/v1/chat/completion` sin la s
  tienen que fallar: un gateway que contesta distinto dos dias para el mismo
  cliente es un gateway que no se puede depurar.

  Y por segmentos y no por cadena porque **la comparacion entera de antes
  hacia que las ocho rutas con `/c/<consumer>` no pudieran coincidir nunca**:
  la tabla declara `/c/:consumer/v1/chat/completions`, y ninguna peticion real
  lleva los dos puntos y la palabra. El «el consumer esta en el camino», que es
  lo que permite servir a varios clientes sin que colisionen sus configuraciones,
  no funcionaba. No se notaba porque no habia servidor.
  """
  @spec match(String.t(), String.t()) :: {:ok, route()} | :error
  def match(method, path) do
    segments = segments(path)

    Enum.find(@routes, fn route ->
      route.method == method and same_segments?(segments(route.path), segments)
    end)
    |> case do
      nil -> :error
      route -> {:ok, route}
    end
  end

  defp segments(path), do: String.split(path, "/")

  # `length/1` NO es una guard valida en Elixir. Puesto en el `when`, esta
  # clausula no casa nunca y el matcher devuelve `false` para todo — es decir,
  # ninguna ruta, ni las que ya funcionaban. Y no da error de compilacion: se
  # queda callada mientras deja el gateway entero sin servir. La comparacion va
  # en el cuerpo, donde si es una condicion normal.
  defp same_segments?(pattern, actual) do
    length(pattern) == length(actual) and
      Enum.zip(pattern, actual)
      |> Enum.all?(fn
        {":consumer", _name} -> true
        {declared, received} -> declared == received
      end)
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
