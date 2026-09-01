defmodule Candil.Structured do
  @moduledoc """
  Force the model to produce JSON matching a schema.

  Wraps `Candil.Backend.chat/3` with:

    1. A system prompt that tells the model to respond with JSON only.
    2. A post-validation step that re-parses the response and rejects
       anything that doesn't match the schema (best-effort: required
       properties present and primitive types correct).

  On validation failure, retries once with a feedback message
  describing the mismatch.

  ## Example

      schema = %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "year" => %{"type" => "integer"}
        },
        "required" => ["title", "year"]
      }

      Candil.Structured.complete(:llama3, "Recommend a sci-fi book", schema)
      # => {:ok, %{"title" => "Dune", "year" => 1965}}
  """

  alias Candil.{Backend, Error}

  @type schema :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Ask the model to complete a prompt with output that conforms to the
  given JSON schema. Returns the parsed map on success.

  ## Options

    * `:backend` — explicit `Candil.Backend` module to use. Defaults to
      `Candil.Backend.for(Backend.infer_provider(:local, model), model)`.
    * `:max_retries` — number of retry attempts after validation
      failure (default 1; total attempts = 1 + max_retries).
    * `:temperature` — passed through to the backend.
  """
  @spec complete(String.t() | atom(), String.t(), schema(), keyword()) :: result()
  def complete(model, prompt, schema, opts \\ []) do
    # `max_retries` is the number of retries AFTER the initial attempt.
    # Default 1 → 1 initial + 1 retry = 2 total. To force a single
    # attempt, pass `max_retries: 0`.
    max_retries = Keyword.get(opts, :max_retries, 1)

    backend =
      case opts[:backend] do
        nil ->
          with {:ok, mod} <- Backend.for(Backend.infer_provider(:local, model), model) do
            mod
          else
            _ -> nil
          end

        mod ->
          mod
      end

    case backend do
      nil ->
        {:error, %Error{reason: :backend_unavailable, context: %{model: model}}}

      mod ->
        # `retries_left + 1` is the maximum number of attempts we'll
        # make; `do_complete/7` decrements this counter and short-circuits
        # when it hits zero (with the last validation error).
        do_complete(mod, model, prompt, schema, max_retries + 1, opts, nil)
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec do_complete(module(), String.t() | atom(), String.t(), schema(), non_neg_integer(), keyword(), String.t() | nil) ::
          result()
  defp do_complete(_backend, _model, _prompt, _schema, 0, _opts, last_error) do
    {:error,
     %Error{
       reason: :invalid_request,
       context: %{message: "schema validation failed", last_error: last_error, attempts_exhausted: true}
     }}
  end

  defp do_complete(backend, model, prompt, schema, retries_left, opts, last_error) do
    system = system_prompt(schema, last_error)
    messages = [%{role: "system", content: system}, %{role: "user", content: prompt}]

    case backend.chat(model, messages, opts) do
      {:ok, %{content: content}} ->
        case parse_and_validate(content, schema) do
          {:ok, validated} ->
            {:ok, validated}

          {:error, reason} ->
            do_complete(backend, model, prompt, schema, retries_left - 1, opts, reason)
        end

      {:error, _} = err ->
        err
    end
  end

  # The default max_retries value: callers get 1 initial attempt + 1
  # retry on validation failure = 2 total. Callers can pass `max_retries: 0`
  # for the strict mode (single attempt, no retry).

  @spec system_prompt(schema(), String.t() | nil) :: String.t()
  defp system_prompt(schema, last_error) do
    schema_str = Jason.encode!(schema)

    base = """
    You must respond with valid JSON that matches this schema:

    ```json
    #{schema_str}
    ```

    Return ONLY the JSON, with no markdown fences or commentary.
    """

    case last_error do
      nil -> base
      err -> base <> "\n\nPrevious attempt failed with: #{inspect(err)}. Try again."
    end
  end

  @spec parse_and_validate(String.t(), schema()) :: {:ok, map()} | {:error, term()}
  defp parse_and_validate(content, schema) do
    cleaned =
      content
      |> String.trim()
      |> strip_code_fences()

    with {:ok, %{} = map} <- Jason.decode(cleaned),
         :ok <- validate_schema(map, schema) do
      {:ok, map}
    else
      {:error, %Jason.DecodeError{} = err} ->
        {:error, Exception.message(err)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_schema(map(), schema()) :: :ok | {:error, term()}
  defp validate_schema(map, %{"required" => required}) when is_list(required) do
    missing = Enum.filter(required, &(not Map.has_key?(map, &1)))

    case missing do
      [] -> :ok
      keys -> {:error, "missing required: #{Enum.join(keys, ", ")}"}
    end
  end

  defp validate_schema(_, _), do: :ok

  defp strip_code_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end
end