defmodule Candil.Telemetry do
  @moduledoc """
  Telemetry events emitted by Candil during LLM inference.

  All events are prefixed with `[:candil, ...]` so a single handler
  can attach to everything Candil does.

  ## Events

    * `[:candil, :inference, :start]` — a chat/embedding/streaming
      request begins. Metadata: `:model`, `:provider`, `:kind`
      (`:chat | :embed | :stream`), `:request_id`.
    * `[:candil, :inference, :stop]` — a request completes successfully.
      Metadata adds `:duration_ms`, `:tokens_in`, `:tokens_out`.
    * `[:candil, :inference, :token]` — a streamed token arrives
      (only fires for `chat_stream`). Metadata: `:request_id`, `:tokens_so_far`.
    * `[:candil, :inference, :error]` — a request fails. Metadata:
      `:model`, `:provider`, `:kind`, `:request_id`, `:reason`,
      `:duration_ms`.
    * `[:candil, :cost, :estimate]` — a cost estimate was computed.
      Metadata: `:provider`, `:model`, `:tokens_in`, `:tokens_out`,
      `:cost_usd`.
    * `[:candil, :cancellation]` — a generation was cancelled.
      Metadata: `:request_id`, `:reason`.

  ## Measurements

  Measurements follow the `duration_in_native_time` convention from
  `:telemetry`. To get milliseconds, use
  `System.convert_time_unit(duration, :native, :millisecond)`.

  ## Example

      :telemetry.attach("candil-logger", [:candil, :inference, :stop], fn _name, measurements, meta, _ ->
        Logger.info("inference done in \#{measurements.duration_ms}ms")
      end, nil)
  """

  alias Arrea.Telemetry, as: Emit

  @type event_kind :: :chat | :embed | :stream

  # Every event is emitted twice, from one place, and that is the Arrea
  # integration: once under `[:candil, ...]` for a host that knows Candil, and
  # once under `[:arrea, :candil_*]` for a host that only ever attached
  # `[:arrea, :*]`.
  #
  # The second one goes through `Arrea.Telemetry.emit/3` rather than
  # `:telemetry.execute/3`, so a host that already has Arrea handlers — metrics,
  # subscribers, dashboards — sees Candil's traffic without attaching anything
  # new and without knowing this library exists. The `candil_` prefix on the
  # type is what lets such a host tell the two apart once it wants to.
  #
  # It is deliberately not `Arrea.Telemetry.measure/2`: that rescues exceptions
  # and returns `{:ok, result}` / `{:error, exception}`, so wrapping an
  # inference call in it would change the call's return type. An observability
  # helper that alters the thing it observes is worse than no helper.

  @doc """
  Emit a `:start` event.
  """
  @spec emit_start(String.t(), event_kind(), map()) :: :ok
  def emit_start(request_id, kind, meta) when is_binary(request_id) and is_atom(kind) do
    execute(
      :candil_inference_start,
      %{system_time: System.system_time()},
      Map.put(meta, :request_id, request_id) |> Map.put(:kind, kind)
    )

    :ok
  end

  @doc """
  Emit a `:stop` event with timing data.
  """
  @spec emit_stop(String.t(), event_kind(), non_neg_integer(), keyword() | map()) :: :ok
  def emit_stop(request_id, kind, duration_native, meta \\ [])
      when is_binary(request_id) and is_atom(kind) and is_integer(duration_native) do
    meta_map =
      meta
      |> Enum.into(%{}, fn {k, v} -> {k, v} end)

    execute(
      :candil_inference_stop,
      %{duration: duration_native},
      Map.put(meta_map, :request_id, request_id) |> Map.put(:kind, kind)
    )

    :ok
  end

  @doc """
  Emit a `:token` event for streaming responses.
  """
  @spec emit_token(String.t(), non_neg_integer()) :: :ok
  def emit_token(request_id, tokens_so_far) do
    execute(:candil_inference_token, %{count: 1}, %{
      request_id: request_id,
      tokens_so_far: tokens_so_far
    })

    :ok
  end

  @doc """
  Emit an `:error` event.
  """
  @spec emit_error(String.t(), event_kind(), non_neg_integer(), atom(), map()) :: :ok
  def emit_error(request_id, kind, duration_native, reason, meta)
      when is_binary(request_id) and is_atom(kind) and is_atom(reason) do
    execute(
      :candil_inference_error,
      %{duration: duration_native},
      Map.merge(meta, %{request_id: request_id, kind: kind, reason: reason})
    )

    :ok
  end

  @doc """
  Emit a `:cost` event.
  """
  @spec emit_cost(atom(), String.t(), non_neg_integer(), non_neg_integer(), float()) :: :ok
  def emit_cost(provider, model, tokens_in, tokens_out, cost_usd) do
    execute(:candil_cost_estimate, %{cost_usd: cost_usd}, %{
      provider: provider,
      model: model,
      tokens_in: tokens_in,
      tokens_out: tokens_out
    })

    :ok
  end

  @doc """
  Emit a `:cancellation` event.
  """
  @spec emit_cancellation(String.t(), atom()) :: :ok
  def emit_cancellation(request_id, reason \\ :cancelled) do
    execute(
      :candil_cancellation,
      %{system_time: System.system_time()},
      %{request_id: request_id, reason: reason}
    )

    :ok
  end

  @doc """
  Emit an engine event. Metadata: `:alias`, `:port`, `:engine`.
  """
  @spec emit_engine(atom(), map()) :: :ok
  def emit_engine(action, meta) when action in [:start, :stop] do
    execute(
      engine_type(action),
      %{system_time: System.system_time()},
      Map.new(meta)
    )
  end

  @doc """
  Emit an HTTP event. Metadata: `:url`, `:breaker`.
  """
  @spec emit_http(atom(), map(), map()) :: :ok
  def emit_http(action, measurements \\ %{}, meta \\ %{})

  def emit_http(action, measurements, meta) when action in [:request, :response] do
    execute(http_type(action), measurements, Map.new(meta))
  end

  # Literals rather than `:"candil_engine_#{action}"`. The guard above already
  # limits `action` to two atoms, and a module attribute turns that limit into
  # something the compiler can see, instead of an atom built on every call from
  # a string the caller controls.
  defp engine_type(:start), do: :candil_engine_start
  defp engine_type(:stop), do: :candil_engine_stop

  defp http_type(:request), do: :candil_http_request
  defp http_type(:response), do: :candil_http_response

  # The one place an event is published. Two namespaces, one call, so a new
  # event cannot be added to one and forgotten in the other — which is the
  # failure mode of having two emit sites and one of them being a copy.
  defp execute(type, measurements, metadata) do
    :telemetry.execute([:candil | candil_path(type)], measurements, metadata)
    Emit.emit(type, measurements, metadata)
    :ok
  end

  # `candil_inference_start` -> [:inference, :start], so the mirrored event keeps
  # the shape a host already knows from the `[:candil, ...]` side.
  #
  # The two-part case is not a special case to be tidy about: `cancellation`
  # has no action, and mapping it to `[:candil, :candil_cancellation]` would
  # quietly rename an event that handlers are already attached to.
  # A literal, decided at compile time.
  #
  # The previous version derived the `[:candil, ...]` path by splitting the
  # type's string and calling `String.to_existing_atom/1` on the halves. That
  # only worked while something else in the module still wrote
  # `[:candil, :inference, :start]` as a literal and kept `:inference` in the
  # atom table; the moment that literal went, the conversion started raising
  # and the mirroring quietly renamed the event instead of failing. A closed set
  # of event names belongs in a map, not in a string round-trip that depends on
  # what some other line happens to have compiled.
  @paths %{
    candil_inference_start: [:inference, :start],
    candil_inference_stop: [:inference, :stop],
    candil_inference_token: [:inference, :token],
    candil_inference_error: [:inference, :error],
    candil_cost_estimate: [:cost, :estimate],
    candil_cancellation: [:cancellation],
    candil_engine_start: [:engine, :start],
    candil_engine_stop: [:engine, :stop],
    candil_http_request: [:http, :request],
    candil_http_response: [:http, :response]
  }

  defp candil_path(type) do
    case @paths do
      %{^type => path} -> path
      %{} -> [type]
    end
  end
end
