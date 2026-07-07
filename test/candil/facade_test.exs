defmodule Candil.FacadeTest do
  use ExUnit.Case, async: true

  describe "Candil facade" do
    setup do
      Code.ensure_loaded(Candil)
      :ok
    end

    test "chat/2 is exported" do
      assert function_exported?(Candil, :chat, 2)
    end

    test "chat/3 is exported" do
      assert function_exported?(Candil, :chat, 3)
    end

    test "chat/4 is exported" do
      assert function_exported?(Candil, :chat, 4)
    end

    test "embed/2 is exported" do
      assert function_exported?(Candil, :embed, 2)
    end

    test "embed/3 is exported" do
      assert function_exported?(Candil, :embed, 3)
    end

    test "embed/4 is exported" do
      assert function_exported?(Candil, :embed, 4)
    end

    test "stream/3 is exported" do
      assert function_exported?(Candil, :stream, 3)
    end

    test "stream/4 is exported" do
      assert function_exported?(Candil, :stream, 4)
    end

    test "stream/5 is exported" do
      assert function_exported?(Candil, :stream, 5)
    end
  end
end
