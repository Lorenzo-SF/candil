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

  @type event_kind :: :chat | :embed | :stream

  @doc """
  Emit a `:start` event.
  """
  @spec emit_start(String.t(), event_kind(), map()) :: :ok
  def emit_start(request_id, kind, meta) when is_binary(request_id) and is_atom(kind) do
    :telemetry.execute(
      [:candil, :inference, :start],
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

    :telemetry.execute(
      [:candil, :inference, :stop],
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
    :telemetry.execute(
      [:candil, :inference, :token],
      %{count: 1},
      %{request_id: request_id, tokens_so_far: tokens_so_far}
    )
    :ok
  end

  @doc """
  Emit an `:error` event.
  """
  @spec emit_error(String.t(), event_kind(), non_neg_integer(), atom(), map()) :: :ok
  def emit_error(request_id, kind, duration_native, reason, meta)
      when is_binary(request_id) and is_atom(kind) and is_atom(reason) do
    :telemetry.execute(
      [:candil, :inference, :error],
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
    :telemetry.execute(
      [:candil, :cost, :estimate],
      %{cost_usd: cost_usd},
      %{
        provider: provider,
        model: model,
        tokens_in: tokens_in,
        tokens_out: tokens_out
      }
    )
    :ok
  end

  @doc """
  Emit a `:cancellation` event.
  """
  @spec emit_cancellation(String.t(), atom()) :: :ok
  def emit_cancellation(request_id, reason \\ :cancelled) do
    :telemetry.execute(
      [:candil, :cancellation],
      %{system_time: System.system_time()},
      %{request_id: request_id, reason: reason}
    )
    :ok
  end
end