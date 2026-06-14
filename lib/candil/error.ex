defmodule Candil.Error do
  @moduledoc """
  Unified error types for Candil.

  All functions in Candil return `{:ok, result}` or `{:error, Candil.Error.t}`
  to provide consistent error handling across the library.
  """

  defexception [:reason, :context]

  @type t :: %__MODULE__{
          reason: reason(),
          context: map()
        }

  @type reason ::
          :model_not_found
          | :engine_not_running
          | :http_error
          | :timeout
          | :rate_limited
          | :invalid_api_key
          | :context_overflow
          | :provider_not_found
          | :invalid_request
          | :engine_exited
          | :startup_timeout
          | term()

  @doc """
  Creates an error for a model that was not found.
  """
  @spec model_not_found(Model.alias() | term()) :: t()
  def model_not_found(model_alias) do
    %__MODULE__{
      reason: :model_not_found,
      context: %{model_alias: model_alias}
    }
  end

  @doc """
  Creates an error for an engine that is not running.
  """
  @spec engine_not_running(Engine.alias() | term()) :: t()
  def engine_not_running(engine_alias) do
    %__MODULE__{
      reason: :engine_not_running,
      context: %{engine_alias: engine_alias}
    }
  end

  @doc """
  Creates an error for an HTTP error with status and optional body.
  """
  @spec http_error(pos_integer(), term()) :: t()
  def http_error(status, body \\ nil) do
    %__MODULE__{
      reason: :http_error,
      context: %{status: status, body: body}
    }
  end

  @doc """
  Creates a timeout error.
  """
  @spec timeout(term()) :: t()
  def timeout(context \\ %{}) do
    %__MODULE__{
      reason: :timeout,
      context: context
    }
  end

  @doc """
  Creates a rate limiting error.
  """
  @spec rate_limited(term()) :: t()
  def rate_limited(retry_after \\ nil) do
    %__MODULE__{
      reason: :rate_limited,
      context: %{retry_after: retry_after}
    }
  end

  @doc """
  Creates an invalid API key error.
  """
  @spec invalid_api_key :: t()
  def invalid_api_key do
    %__MODULE__{
      reason: :invalid_api_key,
      context: %{}
    }
  end

  @doc """
  Creates a context overflow error when messages exceed the model's context window.
  """
  @spec context_overflow(non_neg_integer(), non_neg_integer()) :: t()
  def context_overflow(token_count, max_tokens) do
    %__MODULE__{
      reason: :context_overflow,
      context: %{token_count: token_count, max_tokens: max_tokens}
    }
  end

  @doc """
  Creates a provider not found error.
  """
  @spec provider_not_found(Provider.alias() | term()) :: t()
  def provider_not_found(provider_alias) do
    %__MODULE__{
      reason: :provider_not_found,
      context: %{provider_alias: provider_alias}
    }
  end

  @doc """
  Creates an invalid request error with a message.
  """
  @spec invalid_request(binary()) :: t()
  def invalid_request(message) do
    %__MODULE__{
      reason: :invalid_request,
      context: %{message: message}
    }
  end

  @doc """
  Creates an engine exited error with exit code.
  """
  @spec engine_exited(non_neg_integer(), atom()) :: t()
  def engine_exited(code, model_alias) do
    %__MODULE__{
      reason: :engine_exited,
      context: %{exit_code: code, model_alias: model_alias}
    }
  end

  @doc """
  Creates a startup timeout error.
  """
  @spec startup_timeout(atom()) :: t()
  def startup_timeout(model_alias) do
    %__MODULE__{
      reason: :startup_timeout,
      context: %{model_alias: model_alias}
    }
  end

  @doc """
  Wraps a raw error reason into a Candil.Error.
  """
  @spec wrap(term()) :: t()
  def wrap(reason) when is_struct(reason, __MODULE__), do: reason

  def wrap(reason) do
    %__MODULE__{
      reason: reason,
      context: %{}
    }
  end

  @impl Exception
  def message(%__MODULE__{reason: reason, context: context}) do
    case context do
      %{} when map_size(context) == 0 ->
        "Candil error: #{inspect(reason)}"

      _ ->
        "Candil error: #{inspect(reason)} (#{inspect(context)})"
    end
  end
end
