defmodule Candil.ErrorTest do
  use ExUnit.Case, async: true

  alias Candil.Error

  describe "model_not_found/1" do
    test "creates error with :model_not_found reason" do
      err = Error.model_not_found(:my_model)
      assert err.reason == :model_not_found
      assert err.context.model_alias == :my_model
    end
  end

  describe "engine_not_running/1" do
    test "creates error with :engine_not_running reason" do
      err = Error.engine_not_running(:my_engine)
      assert err.reason == :engine_not_running
      assert err.context.engine_alias == :my_engine
    end
  end

  describe "http_error/2 — status classification (CA-10)" do
    test "401 → :auth_error" do
      err = Error.http_error(401, "Unauthorized")
      assert err.reason == :auth_error
      assert err.context.status == 401
    end

    test "403 → :auth_error" do
      assert Error.http_error(403).reason == :auth_error
    end

    test "429 → :rate_limited" do
      err = Error.http_error(429, "Too Many Requests")
      assert err.reason == :rate_limited
    end

    test "500 → :server_error" do
      err = Error.http_error(500, "Internal Server Error")
      assert err.reason == :server_error
      assert err.context.status == 500
    end

    test "502 → :server_error" do
      assert Error.http_error(502).reason == :server_error
    end

    test "503 → :server_error" do
      assert Error.http_error(503).reason == :server_error
    end

    test "404 → :http_error (generic — not auth/rate/server)" do
      assert Error.http_error(404).reason == :http_error
    end

    test "400 → :http_error" do
      assert Error.http_error(400).reason == :http_error
    end

    test "creates error with just status (default body nil)" do
      err = Error.http_error(500)
      assert err.reason == :server_error
      assert err.context.body == nil
    end

    test "preserves body in context" do
      err = Error.http_error(500, "Internal Server Error")
      assert err.context.body == "Internal Server Error"
    end
  end

  describe "auth_error/2" do
    test "creates error with :auth_error reason" do
      err = Error.auth_error(401, "Bad token")
      assert err.reason == :auth_error
      assert err.context.status == 401
    end
  end

  describe "server_error/2" do
    test "creates error with :server_error reason" do
      err = Error.server_error(502, "Bad Gateway")
      assert err.reason == :server_error
    end
  end

  describe "backend_unavailable/1" do
    test "wraps the reason in context" do
      err = Error.backend_unavailable(:not_loaded)
      assert err.reason == :backend_unavailable
      assert err.context.reason == :not_loaded
    end
  end

  describe "cancelled/1" do
    test "creates error with :cancelled reason and nil ref" do
      err = Error.cancelled()
      assert err.reason == :cancelled
      assert err.context.ref == nil
    end

    test "carries the cancellation ref" do
      ref = make_ref()
      err = Error.cancelled(ref)
      assert err.context.ref == ref
    end
  end

  describe "kind/1" do
    test "returns the same value as reason" do
      err = Error.rate_limited(30)
      assert Error.kind(err) == err.reason
      assert Error.kind(err) == :rate_limited
    end
  end

  describe "timeout/1" do
    test "creates timeout error" do
      err = Error.timeout()
      assert err.reason == :timeout
      assert err.context == %{}
    end

    test "accepts context map" do
      err = Error.timeout(%{url: "https://example.com"})
      assert err.reason == :timeout
      assert err.context.url == "https://example.com"
    end
  end

  describe "rate_limited/1" do
    test "creates rate limited error" do
      err = Error.rate_limited()
      assert err.reason == :rate_limited
      assert err.context.retry_after == nil
    end

    test "accepts retry_after" do
      err = Error.rate_limited(5000)
      assert err.reason == :rate_limited
      assert err.context.retry_after == 5000
    end
  end

  describe "invalid_api_key/0" do
    test "creates invalid api key error" do
      err = Error.invalid_api_key()
      assert err.reason == :invalid_api_key
      assert err.context == %{}
    end
  end

  describe "context_overflow/2" do
    test "creates context overflow error" do
      err = Error.context_overflow(5000, 4096)
      assert err.reason == :context_overflow
      assert err.context.token_count == 5000
      assert err.context.max_tokens == 4096
    end
  end

  describe "provider_not_found/1" do
    test "creates provider not found error" do
      err = Error.provider_not_found(:my_provider)
      assert err.reason == :provider_not_found
      assert err.context.provider_alias == :my_provider
    end
  end

  describe "invalid_request/1" do
    test "creates invalid request error" do
      err = Error.invalid_request("bad input")
      assert err.reason == :invalid_request
      assert err.context.message == "bad input"
    end
  end

  describe "engine_exited/2" do
    test "creates engine exited error" do
      err = Error.engine_exited(1, :my_model)
      assert err.reason == :engine_exited
      assert err.context.exit_code == 1
      assert err.context.model_alias == :my_model
    end
  end

  describe "startup_timeout/1" do
    test "creates startup timeout error" do
      err = Error.startup_timeout(:my_model)
      assert err.reason == :startup_timeout
      assert err.context.model_alias == :my_model
    end
  end

  describe "wrap/1" do
    test "passes through existing Candil.Error" do
      original = Error.model_not_found(:test)
      assert Error.wrap(original) == original
    end

    test "wraps atom reason" do
      err = Error.wrap(:some_error)
      assert err.reason == :some_error
      assert err.context == %{}
    end

    test "wraps string reason" do
      err = Error.wrap("something broke")
      assert err.reason == "something broke"
    end
  end

  describe "message/1" do
    test "formats message without context" do
      err = Error.model_not_found(:test)
      msg = Exception.message(err)
      assert msg =~ "Candil error"
      assert msg =~ ":model_not_found"
    end

test "formats message with context" do
      err = Error.http_error(404, "broken")
      msg = Exception.message(err)
      assert msg =~ "Candil error"
      assert msg =~ ":http_error"
    end
  end
end
