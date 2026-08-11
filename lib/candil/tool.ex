defmodule Candil.Tool do
  @moduledoc """
  Defines a callable tool that an LLM can invoke.

  A tool wraps an Elixir function in a schema that the model can call.
  Use `Candil.Tool.define/4` to register, `Candil.Tool.list/0` to query,
  and `Candil.Tool.call/2` to invoke.

  ## Example

      defmodule MyApp.Tools.Weather do
        use Candil.Tool,
          name: "get_weather",
          description: "Get the current weather for a city",
          schema: %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string"}
            },
            "required" => ["city"]
          }

        def run(%{"city" => city}) do
          {:ok, %{temperature: 21, conditions: "sunny", city: city}}
        end
      end

      Candil.Tool.call("get_weather", %{"city" => "Madrid"})

  ## Custom implementations

  For tools that don't follow the `use Candil.Tool` macro, define a
  `Candil.Tool.t/0` struct manually:

      %Candil.Tool{
        name: "send_email",
        description: "Send an email to a user",
        schema: %{...},
        function: fn args -> MyApp.Mailer.send(args) end
      }
  """

  use GenServer

  @name __MODULE__.Registry

  defstruct [:name, :description, :schema, :function]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: map(),
          function: (map() -> {:ok, term()} | {:error, term()})
        }

  defmacro __using__(args) do
    # Capture `name`, `description`, `schema` from `use` opts; the
    # `run/1` clause is added by the user's module body.
    name = Keyword.fetch!(args, :name)
    desc = Keyword.get(args, :description, "")
    schema = Keyword.get(args, :schema, %{})

    quote do
      @behaviour unquote(__MODULE__)

      def __tool__ do
        %unquote(__MODULE__){
          name: unquote(name),
          description: unquote(desc),
          schema: unquote(schema),
          function: &__MODULE__.run/1
        }
      end
    end
  end

  @doc """
  Define a tool at runtime. Either a `Candil.Tool.t/0` struct or the
  four-tuple `(name, description, schema, function)`.
  """
  @spec define(Candil.Tool.t() | {String.t(), String.t(), map(), function()}) :: :ok
  def define(%__MODULE__{name: name} = tool), do: GenServer.call(@name, {:put, name, tool})
  def define({name, description, schema, function}) when is_binary(name) and is_function(function) do
    define(%__MODULE__{name: name, description: description, schema: schema, function: function})
  end

  @doc """
  List all registered tools.
  """
  @spec list() :: [t()]
  def list, do: GenServer.call(@name, :list)

  @doc """
  Remove all registered tools. Useful for tests and hot-reload scenarios.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(@name, :reset)

  @doc """
  Invoke a tool by name with the given args.

  Returns the tool's return value (`{:ok, term()} | {:error, term()}`)
  on success, or `{:error, %Candil.Error{reason: :not_found}}` if no
  tool with that name is registered.
  """
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(name, args) when is_binary(name) and is_map(args) do
    GenServer.call(@name, {:call, name, args})
  end

  @doc """
  Validate that `args` matches the tool's JSON schema. Returns
  `:ok` if all required properties are present (best-effort; no
  full JSON-schema validation yet).
  """
  @spec validate_args(t(), map()) :: :ok | {:error, term()}
  def validate_args(%__MODULE__{schema: schema, name: name}, args) do
    required = schema["required"] || []

    missing = Enum.filter(required, fn key -> not Map.has_key?(args, key) end)

    case missing do
      [] -> :ok
      keys -> {:error, %Candil.Error{reason: :invalid_request, context: %{tool: name, missing: keys}}}
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @name))
  end

  @impl true
  def init(:ok), do: {:ok, %{tools: %{}}}

  @impl true
  def handle_call({:put, name, tool}, _from, state) do
    {:reply, :ok, %{state | tools: Map.put(state.tools, name, tool)}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.tools), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | tools: %{}}}
  end

  @impl true
  def handle_call({:call, name, args}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, %__MODULE__{function: function}} ->
        {:reply, function.(args), state}

      :error ->
        {:reply, {:error, %Candil.Error{reason: :not_found, context: %{tool: name}}}, state}
    end
  end
end