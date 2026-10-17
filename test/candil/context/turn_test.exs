defmodule Candil.Context.TurnTest do
  use ExUnit.Case, async: true

  alias Candil.Context.Turn

  doctest Turn

  test "new crea un turno con los campos esenciales" do
    turn = Turn.new(:user, "hola")
    assert turn.role == "user"
    assert turn.content == "hola"
    assert %DateTime{} = turn.timestamp
    assert turn.tokens == 0
    assert turn.metadata == %{}
  end

  test "new acepta opciones" do
    now = DateTime.utc_now()
    turn = Turn.new("assistant", "respuesta", tokens: 42, timestamp: now, metadata: %{foo: 1})
    assert turn.tokens == 42
    assert turn.timestamp == now
    assert turn.metadata == %{foo: 1}
  end

  test "new convierte role y content a string" do
    turn = Turn.new(:assistant, 123)
    assert turn.role == "assistant"
    assert turn.content == "123"
  end
end
