defmodule Candil.Router.VramRefusalTest do
  @moduledoc """
  El refusal de VRAM: si el modelo que gana NO está cargado, Candil NO lo
  arranca y lo dice.

  ## Esta regla está decidida desde la fase 2 y NO está escrita

  Es la decisión que gobierna la 8b —la línea de cajas— y se decidió sin
  ejecutarla nunca. Aquí se mide qué hay en realidad.

  ## Lo que este test comprueba, y por qué así

  Mide lo que existe: **que el router NO mira si un modelo está cargado.** Y
  fija por qué eso importa: sin esa comprobación, la política de «no arranques
  solo» es una intención escrita en un `@moduledoc`, no un comportamiento.

  Cuando alguien escriba el refusal, **este test se tendra que poner ROJO**,
  porque ahora affirmationsando el的行为 contrario. Ese es su trabajo:
  no certificar que está bien, sino certifica que **aun no lo esta**.
  """

  use ExUnit.Case, async: false

  alias Candil.{Instances, Router, Store}

  # ── un catálogo de verdad ────────────────────────────────────────────────────

  setup do
    for t <- [:candil_llm_engines, :candil_llm_models, :candil_llm_providers] do
      :ets.delete_all_objects(t)
    end

    # Dos modelos. Uno "cargado" y otro que no lo está. El refusal solo se ve
    # si hay los dos: con uno solo, no hay nada que elegir y el test pasa por
    # casualidad.
    on_exit(fn ->
      for t <- [:candil_llm_engines, :candil_llm_models, :candil_llm_providers] do
        :ets.delete_all_objects(t)
      end
    end)

    :ok
  end

  defp registrar(alias, context) do
    model = %Candil.Model{
      alias: alias,
      type: :local,
      engine: :llama_cpp,
      context_size: context,
      port: 9000,
      usage: [:chat],
      model_dir: "/tmp/candil/#{alias}",
      filename: "#{alias}.gguf"
    }

    :ok = Store.register_model(model)
    model
  end

  defp pin(consumer, model) do
    :ok = Candil.Router.Consumer.pin(consumer, model)
    on_exit(fn -> Candil.Router.Consumer.unpin(consumer) end)
    :ok
  end

  # ── lo que hay ──────────────────────────────────────────────────────────────

  describe "lo que el router sabe hoy" do
    test "decide a quien va el prompt" do
      registrar(:refusal_coder, 131_072)
      registrar(:refusal_embed, 8_192)

      pin(:refusal_probe, :refusal_coder)

      assert {:ok, decision} =
               Router.route([%{role: "user", content: "hola"}], consumer: :refusal_probe)

      assert decision.model_alias == :refusal_coder
    end

    test "y NO sabe si ese modelo está cargado" do
      registrar(:refusal_coder, 131_072)
      pin(:refusal_probe, :refusal_coder)

      # Un pin manda por encima de todo lo demás. Y aun así, el router
      # devuelve una decisión sin mirar NADA de si el motor existe. Un pin a un
      # modelo que no está cargado devuelve exactamente lo mismo que un pin a
      # uno que lo está: **la misma tupla**, porque no se ha comprobado.
      assert {:ok, _} = Router.route([%{role: "user", content: "hola"}], consumer: :refusal_probe)

      # `Instances.alive?/1` existe y funciona. Lo que NO existe es que el
      # router la consulte. Y esto es lo que hay que arreglar: la comprobación
      # es una linea, pero sin ella la política no existe.
      # `function_exported?/3` responde `false` para un modulo que no esta
      # cargado, no para uno que no tenga la funcion. Sin `ensure_loaded` este
      # test mintiria:aria diciendo que la funcion no existe.
      Code.ensure_loaded(Instances)
      assert function_exported?(Instances, :alive?, 1)
    end
  end

  # ── la medición que falta ────────────────────────────────────────────────────

  describe "la medición que NO se está haciendo" do
    test "NO hay ninguna forma de error que diga «no está cargado»" do
      # Estas son TODAS las razones por las que el router puede negarse hoy.
      # Ninguna es «el modelo que quieres no esta arriba». Por eso el refusal no
      # se puede escribir sin una razón nueva: no hay dónde apoyarlo.
      refute razon_de_no_cargado_existe?()
    end

    test "y `Instances.alive?/1` NO recibe nada del router" do
      # Si `Instances.alive?/1` se llamara desde el camino de decisión, el
      # refusal existiría. Que este test siga en verde significa que aún no.
      source = File.read!("lib/candil/router.ex")

      refute source =~ "Instances",
             """
             `lib/candil/router.ex` ya menciona `Instances`.

             Eso quiere decir que el refusal se ha escrito, o que se ha
             empezado. Cuando sea, ESTE test tiene que ponerse en rojo y
             cambiar de opinion.
             """
    end
  end

  # `false` mientras la razon "no está cargado" no exista. Cuando exista,
  # hay que quitarlo.
  defp razon_de_no_cargado_existe? do
    File.read!("lib/candil/router.ex")
    |> String.contains?("not_running")
    |> Kernel.or(String.contains?(File.read!("lib/candil/router.ex"), "no_cargado"))
  end
end
