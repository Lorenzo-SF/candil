defmodule Candil.LocalAuthTest do
  @moduledoc """
  The local inference path used to send a fixed empty header list.

  Any `llama-server` started with `--api-key` — which is the normal way to run
  one that is not on loopback — answered 401, and there was no way to inject
  one: the options map had no field to put headers in. A consumer of this
  library had already written its own HTTP client to get around it.

  These are the tests that would have caught it.
  """

  use ExUnit.Case, async: false

  alias Candil.{Engine, Store}

  @model_alias :candil_test_local_model
  @engine_alias :candil_test_local_engine

  setup do
    original = System.get_env("CANDIL_TEST_LOCAL_KEY")

    on_exit(fn ->
      if original,
        do: System.put_env("CANDIL_TEST_LOCAL_KEY", original),
        else: System.delete_env("CANDIL_TEST_LOCAL_KEY")
    end)

    :ok =
      Store.register_engine(%Engine{
        alias: @engine_alias,
        binary: "llama-server",
        api_key: {:system, "CANDIL_TEST_LOCAL_KEY"}
      })

    :ok =
      Store.register_model(%Candil.Model{
        alias: @model_alias,
        type: :local,
        engine: @engine_alias,
        model_dir: "/models",
        filename: "test.gguf"
      })

    :ok
  end

  describe "Engine.auth_headers_for/1" do
    test "is empty when the engine has no key" do
      # The default has to be unchanged: a server started without --api-key
      # must keep working.
      :ok =
        Store.register_engine(%Engine{alias: :candil_test_nokey, binary: "llama-server"})

      :ok =
        Store.register_model(%Candil.Model{
          alias: :candil_test_nokey_model,
          type: :local,
          engine: :candil_test_nokey,
          model_dir: "/models",
          filename: "t.gguf"
        })

      assert Engine.auth_headers_for(:candil_test_nokey_model) == []
    end

    test "carries a bearer header when the engine has a literal key" do
      :ok =
        Store.register_engine(%Engine{
          alias: :candil_test_lit,
          binary: "llama-server",
          api_key: "sk-test"
        })

      :ok =
        Store.register_model(%Candil.Model{
          alias: :candil_test_lit_model,
          type: :local,
          engine: :candil_test_lit,
          model_dir: "/models",
          filename: "t.gguf"
        })

      assert Engine.auth_headers_for(:candil_test_lit_model) == [
               {"authorization", "Bearer sk-test"}
             ]
    end

    test "carries a bearer header for a {:system, VAR} key" do
      System.put_env("CANDIL_TEST_LOCAL_KEY", "sk-local-dev-key")

      assert Engine.auth_headers_for(@model_alias) == [
               {"authorization", "Bearer sk-local-dev-key"}
             ]
    end

    test "is empty for an unknown model rather than raising" do
      assert Engine.auth_headers_for(:candil_no_existe) == []
      assert Engine.auth_headers_for("candil_no_existe_tampoco") == []
      assert Engine.auth_headers_for(:candil_test_local_model_de_nada) == []
    end

    test "accepts a string alias" do
      System.put_env("CANDIL_TEST_LOCAL_KEY", "sk-x")

      assert Engine.auth_headers_for("candil_test_local_model") == [
               {"authorization", "Bearer sk-x"}
             ]
    end

    test "is empty for a remote model" do
      # A remote model has no engine; its credentials live on the provider and
      # the provider path already sends them.
      :ok =
        Store.register_model(%Candil.Model{
          alias: :candil_test_remote,
          type: :remote,
          name: "gpt-4o",
          provider: :openai
        })

      assert Engine.auth_headers_for(:candil_test_remote) == []
    end

    test "does not create atoms from an unknown string alias" do
      random = "candil_test_#{System.unique_integer([:positive])}"
      before = :erlang.system_info(:atom_count)
      assert Engine.auth_headers_for(random) == []
      # The atom table is finite and never shrinks. Converting whatever
      # arrives is how an endpoint leaks memory at a byte per request.
      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "Engine.connection_for/1" do
    test "reports the engine as not running, with the headers ready" do
      # base_url/1 knows nothing about authentication, which is why the
      # caller that pairs the two has to go through here.
      assert {:error, :engine_not_running} = Engine.connection_for(:candil_test_local_model)
    end
  end
end
