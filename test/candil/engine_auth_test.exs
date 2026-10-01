defmodule Candil.EngineAuthTest do
  @moduledoc """
  The local inference path used to send a fixed empty header list, so any
  `llama-server` started with `--api-key` answered 401 and there was no way to
  inject one. These are the tests that would have caught it.
  """

  use ExUnit.Case, async: false

  alias Candil.Engine

  describe "api_key/1" do
    test "is nil when unset" do
      assert Engine.api_key(%Engine{alias: :e}) == nil
    end

    test "passes a literal string through" do
      assert Engine.api_key(%Engine{alias: :e, api_key: "sk-local-dev-key"}) == "sk-local-dev-key"
    end

    test "resolves {:system, VAR} from the environment" do
      System.put_env("CANDIL_ENGINE_TEST_KEY", "from-env")
      on_exit(fn -> System.delete_env("CANDIL_ENGINE_TEST_KEY") end)

      assert Engine.api_key(%Engine{alias: :e, api_key: {:system, "CANDIL_ENGINE_TEST_KEY"}}) ==
               "from-env"
    end

    test "resolves the environment at call time, not at build time" do
      # A key exported after the application boots must still be found, or a
      # systemd-style unit that loads an env file first would break.
      System.delete_env("CANDIL_ENGINE_TEST_LATE")
      engine = %Engine{alias: :e, api_key: {:system, "CANDIL_ENGINE_TEST_LATE"}}
      assert Engine.api_key(engine) == nil

      System.put_env("CANDIL_ENGINE_TEST_LATE", "late")
      on_exit(fn -> System.delete_env("CANDIL_ENGINE_TEST_LATE") end)
      assert Engine.api_key(engine) == "late"
    end

    test "treats an unset or empty variable as no key" do
      System.put_env("CANDIL_ENGINE_TEST_EMPTY", "")
      on_exit(fn -> System.delete_env("CANDIL_ENGINE_TEST_EMPTY") end)

      assert Engine.api_key(%Engine{alias: :e, api_key: {:system, "CANDIL_ENGINE_TEST_EMPTY"}}) ==
               nil

      assert Engine.api_key(%Engine{alias: :e, api_key: {:system, "CANDIL_ENGINE_TEST_MISSING"}}) ==
               nil
    end
  end

  describe "auth_headers/1" do
    test "is empty when there is no key, so the default is unchanged" do
      assert Engine.auth_headers(%Engine{alias: :e}) == []
    end

    test "adds a bearer header for a literal key" do
      assert Engine.auth_headers(%Engine{alias: :e, api_key: "sk-x"}) == [
               {"authorization", "Bearer sk-x"}
             ]
    end

    test "adds a bearer header for an environment key" do
      System.put_env("CANDIL_ENGINE_TEST_H", "sk-env")
      on_exit(fn -> System.delete_env("CANDIL_ENGINE_TEST_H") end)

      engine = %Engine{alias: :e, api_key: {:system, "CANDIL_ENGINE_TEST_H"}}
      assert Engine.auth_headers(engine) == [{"authorization", "Bearer sk-env"}]
    end

    test "keeps explicit auth_headers and puts the bearer first" do
      engine = %Engine{
        alias: :e,
        api_key: "sk-x",
        auth_headers: [{"x-trace", "abc"}]
      }

      assert Engine.auth_headers(engine) == [
               {"authorization", "Bearer sk-x"},
               {"x-trace", "abc"}
             ]
    end

    test "passes explicit headers through when there is no key" do
      engine = %Engine{alias: :e, auth_headers: [{"x-trace", "abc"}]}
      assert Engine.auth_headers(engine) == [{"x-trace", "abc"}]
    end
  end

  describe "base_url_and_headers/2" do
    test "pairs the URL with the auth headers, unlike base_url/1" do
      engine = %Engine{alias: :e, host: "127.0.0.1", api_key: "sk-x"}

      assert {"http://127.0.0.1:9999", [{"authorization", "Bearer sk-x"}]} =
               Engine.base_url_and_headers(engine, 9999)
    end

    test "does not silently drop the key, which was the original bug" do
      # The first version of this function built the URL from the engine but
      # the headers from a fresh engine with the key blanked. It type-checked,
      # it compiled, and it reintroduced the 401 it was written to fix.
      engine = %Engine{alias: :e, host: "10.0.0.5", api_key: "sk-real"}
      {url, headers} = Engine.base_url_and_headers(engine, 8080)

      assert url == "http://10.0.0.5:8080"
      assert headers == [{"authorization", "Bearer sk-real"}]
    end
  end
end
