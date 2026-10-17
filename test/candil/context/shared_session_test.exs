defmodule Candil.Context.SharedSessionTest do
  use ExUnit.Case, async: true

  alias Candil.Context.{SharedSession, Turn}

  doctest SharedSession

  test "new crea una sesion vacia" do
    session = SharedSession.new(:posadero, "s1")
    assert session.consumer == :posadero
    assert session.id == "s1"
    assert session.turns == []
    assert SharedSession.turn_count(session) == 0
  end

  test "add_turn añade un turno" do
    session = SharedSession.new(:posadero, "s1")
    turn = Turn.new(:user, "hola")
    session = SharedSession.add_turn(session, turn)
    assert SharedSession.turn_count(session) == 1
    assert hd(session.turns) == turn
  end

  test "add_turn con rol y contenido crea el turno" do
    session = SharedSession.new(:posadero, "s1")
    session = SharedSession.add_turn(session, :assistant, "respuesta", tokens: 10)
    assert SharedSession.turn_count(session) == 1
    assert hd(session.turns).role == "assistant"
    assert hd(session.turns).tokens == 10
  end

  test "varios turnos se acumulan en orden" do
    session = SharedSession.new(:posadero, "s1")
    session = SharedSession.add_turn(session, :user, "uno")
    session = SharedSession.add_turn(session, :assistant, "dos")
    assert SharedSession.turn_count(session) == 2
    assert Enum.map(session.turns, & &1.content) == ["uno", "dos"]
  end
end
