defmodule Candil.TelemetryTest do
  @moduledoc """
  The Arrea mirroring is the integration, and an integration nobody asserts is
  an integration that quietly stops happening.
  """
  use ExUnit.Case, async: false

  alias Candil.Telemetry

  setup do
    id = "candil-telemetry-test-#{System.unique_integer([:positive])}"
    handler = fn name, _measurements, _meta, _config -> send(self(), {:event, name}) end

    :telemetry.attach_many(
      id,
      [[:arrea, :candil_inference_start], [:candil, :inference, :start]],
      handler,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  describe "the two namespaces" do
    test "an event is visible to a host that only ever attached to :arrea" do
      # This is the whole reason the mirroring exists: a host that already
      # instruments Arrea sees Candil without attaching anything new.
      Telemetry.emit_start("r1", :chat, %{model: "coder"})

      assert_receive {:event, [:arrea, :candil_inference_start]}
    end

    test "and Candil's own event is unchanged, so existing handlers keep working" do
      Telemetry.emit_start("r1", :chat, %{model: "coder"})

      assert_receive {:event, [:candil, :inference, :start]}
    end

    test "a two-part event name is not renamed by the mirroring" do
      # `candil_cancellation` has no action to split off, and the naive
      # mapping turned `[:candil, :cancellation]` into
      # `[:candil, :candil_cancellation]` — a silent rename of an event that
      # handlers are already attached to.
      id = "candil-cancel-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        id,
        [[:candil, :cancellation]],
        fn name, _m, _meta, _config -> send(self(), {:event, name}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      Telemetry.emit_cancellation("r1")

      assert_receive {:event, [:candil, :cancellation]}
    end
  end

  describe "metadata" do
    test "the model and the kind travel with the event" do
      Telemetry.emit_start("r42", :stream, %{model: "coder", provider: :ollama})

      assert_receive {:event, [:arrea, :candil_inference_start]}
      assert_receive {:event, [:candil, :inference, :start]}

      # the handler captures the whole envelope, so read it back
      id = "candil-meta-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:candil, :inference, :start],
        fn _name, _m, meta, _config -> send(self(), {:meta, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      Telemetry.emit_start("r42", :stream, %{model: "coder", provider: :ollama})
      assert_receive {:meta, meta}

      assert meta.model == "coder"
      assert meta.provider == :ollama
      assert meta.kind == :stream
      assert meta.request_id == "r42"
    end
  end
end
