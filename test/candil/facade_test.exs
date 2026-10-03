defmodule Candil.FacadeTest do
  use ExUnit.Case, async: true

  describe "Candil facade" do
    setup do
      Code.ensure_loaded(Candil)
      :ok
    end

    test "chat/2 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :chat, 2)
    end

    test "chat/3 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :chat, 3)
    end

    test "chat/4 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :chat, 4)
    end

    test "embed/2 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :embed, 2)
    end

    test "embed/3 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :embed, 3)
    end

    test "embed/4 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :embed, 4)
    end

    test "stream/3 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :stream, 3)
    end

    test "stream/4 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :stream, 4)
    end

    test "stream/5 is exported" do
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      # `function_exported?/3` answers false for a module that is not loaded yet, so
      # this asserts a question about load order unless the module is loaded first.
      # `http_test.exs` says the same thing; the trap was fixed in one file and
      # left in the others, where a change of seed is what finally showed it.
      {:module, Candil} = Code.ensure_loaded(Candil)
      assert function_exported?(Candil, :stream, 5)
    end
  end
end
