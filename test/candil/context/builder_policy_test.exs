defmodule Candil.Context.BuilderPolicyTest do
  @moduledoc """
  §3.4 y D4: qué pasa cuando no cabe, y qué dice el error.

  La versión anterior devolvía `{:error, :context_exceeded}` para tres cosas
  distintas y recortaba el historial sin avisar. Un consumidor que tiene que
  reaccionar —subir la ventana, acortar el prompt, dejar ir la historia— recibia
  un error que no le decia cual, y un contexto recortado que parecia entero.
  """
  use ExUnit.Case, async: true

  alias Candil.Context.{Builder, Session}

  defp session_with(n, chars \\ 400) do
    session = Session.new(:posadero, "s1")

    Enum.reduce(1..n, session, fn i, acc ->
      Session.add_message(acc, "user", String.duplicate("#{i}", chars))
    end)
  end

  defp new_message(text \\ "hola"), do: [%{role: "user", content: text}]

  describe "el error dice QUE no cabe" do
    test ":budget_exhausted cuando lo que no cabe es el mensaje nuevo" do
      # El error anterior era `:context_exceeded` a secas, para todo.
      assert {:error, {:context_exceeded, :budget_exhausted}} =
               Builder.build(session_with(1), new_message(String.duplicate("x", 4_000)),
                 context_size: 1_000
               )
    end

    test ":no_room_for_system cuando no cabe ni el prompt del sistema" do
      # `margin_tokens: 0` a proposito: con el margen de 512 por defecto y una
      # ventana de 100, la ventana sale CERO y el diagnostico correcto seria
      # `:budget_exhausted` —el presupuesto se ha comido la ventana entera—,
      # no que el prompt del sistema no quepa.
      assert {:error, {:context_exceeded, :no_room_for_system}} ==
               Builder.build(session_with(0), new_message("hola"),
                 context_size: 500,
                 margin_tokens: 0,
                 system_prompt: String.duplicate("reglas ", 400)
               )
    end

    test ":no_room_to_truncate cuando la historia no cabe y no se puede recortar" do
      # Con la historia larga y `:strict`, la ventana se llena por detrás y no
      # hay por donde meterse.
      assert Builder.build(session_with(40), new_message(), context_size: 900) ==
               {:error, {:context_exceeded, :no_room_to_truncate}}
    end
  end

  describe ":compact" do
    test "recorta la historia y DICE cuanta" do
      assert {:ok, messages} =
               Builder.build(session_with(40), new_message(), context_size: 900, policy: :compact)

      # Y la pregunta sigue al final: lo que se tira es lo viejo, no lo nuevo.
      assert List.last(messages) == %{role: "user", content: "hola"}
      assert length(messages) < 42, "deberia haberse recortado historia"
    end

    test "el mensaje nuevo que no cabe es error en las TRES politicas" do
      # Si lo que no cabe es el mensaje nuevo, ni recortar ni resumir
      # ayudan: solo una ventana mayor. Y mandarlo igualmente produce un 400
      # del servidor, o peor, un recorte que nadie ha pedido.
      assert Builder.build(session_with(1), new_message(String.duplicate("x", 4_000)),
               context_size: 1_000,
               policy: :compact
             ) == {:error, {:context_exceeded, :budget_exhausted}}
    end
  end

  describe ":summarize" do
    test "NO degrada a un recorte cuando el resumen no ayuda" do
      # Sin modelo disponible `Summarizer` devuelve la sesion intacta, y la
      # reconstruccion vuelve a no caber. El resultado es un ERROR, no un
      # recorte por debajo: una politica que se convierte en otra cuando las
      # cosas se ponen dificiles es peor que no tener politica.
      assert Builder.build(session_with(40), new_message(),
               context_size: 900,
               policy: :summarize
             ) == {:error, {:context_exceeded, :no_room_to_truncate}}
    end
  end

  describe "el contrato" do
    test "la forma del exito no cambia: sigue siendo una tupla de dos" do
      # Se podia haber anadido un tercer elemento con cuantos mensajes se
      # perdieron. No se hace: `:strict` no recorta nunca, y en `:compact` el
      # recorte es justo lo que se ha pedido. El exito es `{:ok, messages}` como
      # lo ha sido siempre, y lo unico que cambia es el error.
      assert {:ok, messages} =
               Builder.build(session_with(2), new_message(), context_size: 8_000)

      assert messages != []
    end
  end
end
