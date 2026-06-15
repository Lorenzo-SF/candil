defmodule Candil.StreamTest do
  use ExUnit.Case, async: true

  alias Candil.{Error, Stream}

  describe "chat/4 (local)" do
    test "returns error when engine not running" do
      callback = fn _chunk -> :ok end

      result = Stream.chat(:nonexistent_model, [%{role: "user", content: "Hello"}], callback, [])

      assert {:error,
              %Error{reason: :engine_not_running, context: %{engine_alias: :nonexistent_model}}} =
               result
    end
  end
end
