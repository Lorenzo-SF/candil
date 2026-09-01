defmodule Candil.TelemetryTest do
  use ExUnit.Case, async: false

  alias Candil.Telemetry

  setup do
    handler_id = "candil-test-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:candil, :inference, :start],
        [:candil, :inference, :stop],
        [:candil, :inference, :token],
        [:candil, :inference, :error],
        [:candil, :cost, :estimate],
        [:candil, :cancellation]
      ],
      fn name, measurements, meta, _config ->
        send(parent, {:telemetry, name, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, handler_id: handler_id}
  end

  test "emit_start/3 fires [:candil, :inference, :start]", _ctx do
    assert :ok = Telemetry.emit_start("req-1", :chat, %{model: "gpt-4o"})

    assert_received {:telemetry, [:candil, :inference, :start], _measurements, meta}
    assert meta.request_id == "req-1"
    assert meta.kind == :chat
    assert meta.model == "gpt-4o"
  end

  test "emit_stop/4 fires [:candil, :inference, :stop] with duration", _ctx do
    assert :ok = Telemetry.emit_stop("req-1", :chat, 100_000, tokens_in: 10, tokens_out: 5)
    assert_received {:telemetry, [:candil, :inference, :stop], %{duration: 100_000}, meta}
    assert meta.request_id == "req-1"
    assert meta.tokens_in == 10
    assert meta.tokens_out == 5
  end

  test "emit_token/2 fires for every streamed chunk", _ctx do
    assert :ok = Telemetry.emit_token("req-1", 1)
    assert :ok = Telemetry.emit_token("req-1", 2)

    assert_received {:telemetry, [:candil, :inference, :token], _, %{tokens_so_far: 1}}
    assert_received {:telemetry, [:candil, :inference, :token], _, %{tokens_so_far: 2}}
  end

  test "emit_error/5 fires [:candil, :inference, :error]", _ctx do
    assert :ok = Telemetry.emit_error("req-1", :chat, 100_000, :timeout, %{model: "gpt-4o"})

    assert_received {:telemetry, [:candil, :inference, :error], _, meta}
    assert meta.reason == :timeout
    assert meta.kind == :chat
  end

  test "emit_cost/5 fires [:candil, :cost, :estimate]", _ctx do
    assert :ok = Telemetry.emit_cost(:openai, "gpt-4o", 100, 50, 0.0025)
    assert_received {:telemetry, [:candil, :cost, :estimate], %{cost_usd: 0.0025}, meta}
    assert meta.tokens_in == 100
    assert meta.tokens_out == 50
  end

  test "emit_cancellation/2 fires [:candil, :cancellation]", _ctx do
    assert :ok = Telemetry.emit_cancellation("req-1", :cancelled)
    assert_received {:telemetry, [:candil, :cancellation], _, meta}
    assert meta.reason == :cancelled
  end
end