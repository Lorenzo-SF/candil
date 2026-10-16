defmodule Candil.Router.ConsumerTest do
  @moduledoc """
  El reparto de un consumer: qué modelos puede usar, y **qué pasa cuando el
  toml nombra uno que no está**.

  ## El fallo que esto vigila, medido

  Escrito el 2026-10-15, y **no es hipotético**: con un `candil.toml` cuyo
  `[consumer.X] models` nombraba un alias que no existía como átomo en la VM,

      (ArgumentError) errors were found at the given arguments:
        * 1st argument: not an already existing atom
        :erlang.binary_to_existing_atom("coder_lite")
        (candil 4.0.0) lib/candil/router/consumer.ex:76: Consumer.candidates/1
        (candil 4.0.0) lib/candil/gateway/handlers/models.ex:25: Models.call/2

  y el cliente recibía un **500 con el cuerpo vacío**: `GET /v1/models` sin
  nada que leer, que es la peor forma de fallar que tiene un gateway. La causa
  está en `model_alias!/1`: `String.to_existing_atom/1` a pelo —sin el `rescue`
  que sí tiene el mismo patrón en `ChatCompletions.existing_alias/1`— convierte
  una errata del fichero de configuración en un crash de la petición.

  La decisión: un nombre que no existe es `{:error, {:unknown_model, nombre}}`,
  que es un error que **ya sabía pintarse** (`Gateway.error_body/1` lo convierte
  en un 400 «no model named … is registered») y que el llamante puede corregir.
  Un alias que no está no se sustituye por otro modelo: eso es contestar una
  pregunta que nadie ha hecho, que es lo que D-04 dejó escrito para las cifras
  de VRAM.
  """

  use ExUnit.Case, async: false

  alias Candil.Router.Consumer

  defp con_config(toml) do
    tmp = Path.join(System.tmp_dir!(), "candil-consumer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "candil.toml"), toml)

    Candil.TestConfig.override!(Path.join(tmp, "candil.toml"))
    on_exit(fn -> File.rm_rf(tmp) end)

    :ok
  end

  describe "candidates/1" do
    test "los nombres que existen salen en el orden del toml" do
      con_config("""
      [consumer.default]
      model_default = "ok"
      models        = ["error", "ok"]
      """)

      assert Consumer.candidates(:default) == {:ok, [:error, :ok]}
    end

    test "sin `models`, el candidato es `model_default`" do
      con_config("""
      [consumer.default]
      model_default = "ok"
      """)

      assert Consumer.candidates(:default) == {:ok, [:ok]}
    end

    # La trampa que hace que este test sea el test: `:sin_atomo_ni_modelo`
    # escrito como **átomo** en este fichero crearía el átomo al compilar, y
    # entonces `String.to_existing_atom/1` acertaría y el fallo que se vigila
    # dejaría de existir. Va como cadena, y la cadena no crea nada.
    test "un nombre que no existe es un error que dice cuál, no un crash" do
      con_config("""
      [consumer.default]
      model_default = "ok"
      models        = ["ok", "sin_atomo_ni_modelo"]
      """)

      assert Consumer.candidates(:default) ==
               {:error, {:unknown_model, "sin_atomo_ni_modelo"}}
    end

    test "lo mismo para un `model_default` que no existe" do
      con_config("""
      [consumer.default]
      model_default = "tampoco_es_un_modelo"
      """)

      assert Consumer.candidates(:default) ==
               {:error, {:unknown_model, "tampoco_es_un_modelo"}}
    end
  end
end
