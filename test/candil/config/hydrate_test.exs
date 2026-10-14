defmodule Candil.Config.HydrateTest do
  use ExUnit.Case, async: false

  alias Candil.{Build, Model, Source, Store}
  alias Candil.Config.{File, Hydrate}

  @ropero Path.expand("../../fixtures/config/ejemplo.toml", __DIR__)

  setup do
    # The Store is application state and the supervisor starts it for the
    # whole suite, so each test empties it rather than assuming it is clean.
    Enum.each(Store.list_models(), &Store.deregister_model(&1.alias))
    Enum.each(Store.list_engines(), &Store.deregister_engine(&1.alias))
    Enum.each(Store.list_providers(), &Store.deregister_provider(&1.alias))
    :ok
  end

  defp load!(path \\ @ropero) do
    {:ok, config} = File.load(path)
    config
  end

  describe "el ejemplo de test/fixtures/config" do
    test "every section registers without a single error" do
      result = Hydrate.hydrate(load!())

      # Properties, not the aliases of somebody's file. This fixture exists to
      # check that hydration WORKS, and an assertion that names `coder_lite`
      # would be asserting that the file still has `coder_lite` in it — which is
      # a test that rots the moment anyone edits the example.
      assert result.engines == [:llama_cpp]
      assert result.providers == [:openai]
      assert :coder in result.models
      assert Enum.sort(result.models) == Enum.sort([:coder, :embed, :quick, :gpt4o])
    end

    test "the models land in the Store" do
      Hydrate.hydrate(load!())

      assert 4 = length(Store.list_models())
      assert 1 = length(Store.list_engines())
      assert 1 = length(Store.list_providers())
    end

    test "a local model knows where its file is" do
      # The one that was hardest to get right. `Source.dest_path/1` matches on
      # an atom `:kind`, so a `kind` left as the string "huggingface" falls
      # through every clause and answers nil — and the model is then rejected
      # for having no file, with a message that never mentions the kind.
      Hydrate.hydrate(load!())

      assert {:ok, coder} = Store.get_model(:coder)
      assert coder.source.kind == :huggingface
      assert Model.file_path(coder) =~ "coder"
      refute Model.file_path(coder) == ""
    end

    test "la `description` llega al modelo, y llega la que no hay" do
      # El camino entero: la `description` del TOML es lo UNICO que la capa
      # `:embedding` del router tiene para comparar con un prompt. Si aqui se
      # perdiera —porque `Hydrate` no la copiase, o porque se atomizase— la
      # capa devolveria `:miss` en cualquier maquina y no habria forma de saber
      # que el dato estaba en el fichero todo el tiempo.
      Hydrate.hydrate(load!())

      assert {:ok, coder} = Store.get_model(:coder)
      assert coder.description == "escribe, explica y arregla codigo en Elixir y Python"

      # Y el caso contrario tambien: un modelo sin descripcion la tiene a `nil`,
      # no a `""` y no a un texto inventado a partir del alias.
      assert {:ok, gpt4o} = Store.get_model(:gpt4o)
      assert gpt4o.description == nil
    end

    test "paths are expanded, so no literal tilde survives" do
      # `load/1` hands the document back as written; `expand/1` is a separate
      # call. Skipping it leaves `~` literal, and then every model is rejected
      # as having no locatable file.
      Hydrate.hydrate(load!())

      for model <- Store.list_models(), Model.managed?(model) do
        refute Model.file_path(model) =~ "~"
      end

      {:ok, engine} = Store.get_engine(:llama_cpp)
      assert engine.install.src_dir =~ "/"
      refute engine.install.src_dir =~ "~"
    end

    test "the engine keeps the install plan, generator and the user's flags" do
      Hydrate.hydrate(load!())

      {:ok, engine} = Store.get_engine(:llama_cpp)
      assert engine.install.strategy == :source
      assert engine.install.generator == :ninja
      assert Enum.any?(engine.install.cmake_args, &(&1 =~ "CMAKE_BUILD_TYPE"))
      assert engine.install.binaries == ["llama-server", "llama-cli"]
    end

    test "the auth section becomes a system variable, not a literal key" do
      Hydrate.hydrate(load!())

      {:ok, engine} = Store.get_engine(:llama_cpp)
      assert engine.api_key == {:system, "LLAMA_API_KEY"}
    end

    test "a remote model carries its provider, and the provider its env key" do
      Hydrate.hydrate(load!())

      assert {:ok, gpt4o} = Store.get_model(:gpt4o)
      assert gpt4o.type == :remote
      assert gpt4o.provider == :openai

      assert {:ok, provider} = Store.get_provider(:openai)
      assert provider.type == :openai
      assert provider.base_url == "https://api.openai.com"
    end

    test "the draft of a model with a source is expanded too" do
      Hydrate.hydrate(load!())

      assert {:ok, quick} = Store.get_model(:quick)
      assert quick.draft.kind == :huggingface
      assert Source.dest_path(quick.draft) =~ "Qwen3-0.6B-Q4_K_XL.gguf"
      refute Source.dest_path(quick.draft) =~ "~"
    end
  end

  describe "aliases" do
    test "an alias is taken from a key that is already an identifier" do
      config = %{
        "model" => %{"good_name" => %{"type" => "remote", "provider" => "p", "name" => "x"}}
      }

      assert %{models: [:good_name]} = Hydrate.hydrate(config)
    end

    test "a key that is not an identifier is refused, not turned into an atom" do
      # The whole reason `to_existing_atom/1` is tried first and the fallback
      # checks the shape. Any name that is not `[a-z][a-z0-9_]*` is not an
      # alias someone typo'd; it is not an alias at all.
      config = %{
        "model" => %{"Bad Name!" => %{"type" => "remote", "provider" => "p", "name" => "x"}}
      }

      assert %{models: [{:error, "Bad Name!", [message]}]} = Hydrate.hydrate(config)
      assert message =~ "not [a-z][a-z0-9_]*"
    end

    test "a second load reuses the atoms the first one made" do
      # `to_existing_atom/1` is a fast path, not a guard — on a cold start the
      # fallback always fires. It is asserted so that stays a known property
      # rather than an accident nobody re-checks.
      config = %{
        "model" => %{"reuse_me" => %{"type" => "remote", "provider" => "p", "name" => "x"}}
      }

      assert %{models: [:reuse_me]} = Hydrate.hydrate(config)
      assert %{models: [:reuse_me]} = Hydrate.hydrate(config)
    end
  end

  describe "failures are contained" do
    test "one bad model does not cost the good ones" do
      config = %{
        "model" => %{
          "ok" => %{"type" => "remote", "provider" => "p", "name" => "x"},
          "broken" => %{"type" => "local"}
        }
      }

      result = Hydrate.hydrate(config)
      assert :ok in result.models
      assert {:error, "broken", [_ | _]} = Enum.find(result.models, &match?({:error, _, _}, &1))
    end

    test "a section that is not a table is reported, not crashed on" do
      assert %{models: [{:error, "model", [message]}]} =
               Hydrate.hydrate(%{"model" => "nope"})

      assert message =~ "must be a table"
    end

    test "an empty document is an empty catalogue, not an error" do
      assert %{engines: [], models: [], providers: []} = Hydrate.hydrate(%{})
    end
  end

  defp hydrate_model(usage) do
    %{
      "model" => %{
        "codigo" => %{
          "type" => "local",
          "engine" => "nope",
          "usage" => usage,
          "model_dir" => "/modelos",
          "filename" => "codigo.gguf"
        }
      }
    }
    |> Hydrate.hydrate()
  end

  # `usage` mezclaba endpoints y capacidades. Medido sobre el catalogo real el
  # 2026-10-14, cuatro modelos de siete declaraban `["chat", "reasoning"]` o
  # `["chat", "code", "completion"]`. Estos tests usan **esas cadenas literales**
  # a proposito: si un dia se rompe la migracion, se rompe aqui y no al arrancar
  # con el catalogo de alguien.
  describe "la separacion de usage en endpoints y capacidades" do
    test "un endpoint se queda en usage" do
      assert %{models: [:codigo]} = hydrate_model(["chat"])
    end

    test "una capacidad migra sola a capabilities, y no se pierde" do
      # `["chat", "code", "completion"]` es literal del catalogo real.
      %{models: [:codigo]} = hydrate_model(["chat", "code", "completion"])

      model = elem(Store.get_model(:codigo), 1)

      assert model.usage == [:chat, :completion]
      assert model.capabilities == [:code]
    end

    test "varias capacidades a la vez" do
      # `["chat", "reasoning"]` es literal del catalogo real, y `reasoning` es
      # justo lo que lee el filtro de dificultad del router.
      %{models: [:codigo]} = hydrate_model(["chat", "reasoning"])

      model = elem(Store.get_model(:codigo), 1)

      assert model.usage == [:chat]
      assert model.capabilities == [:reasoning]
    end

    test "solo endpoints deja capabilities vacio" do
      %{models: [:codigo]} = hydrate_model(["embeddings"])

      model = elem(Store.get_model(:codigo), 1)

      assert model.usage == [:embeddings]
      assert model.capabilities == []
    end

    test "un valor que no es ni endpoint ni capacidad NO se inventa" do
      # Esto es lo que evita que un typo se convierta en un modelo que finge
      # saber algo: se levanta en vez de dejar el valor donde estaba.
      assert_raise ArgumentError, ~r/no es ni un endpoint ni una capacidad/, fn ->
        hydrate_model(["chat", "chatt"])
      end
    end
  end

  describe "escribir capabilities en el toml" do
    test "la forma nueva se lee, y es la que no migra" do
      %{models: [:codigo]} =
        Hydrate.hydrate(%{
          "model" => %{
            "codigo" => %{
              "type" => "local",
              "engine" => "nope",
              "model_dir" => "/modelos",
              "filename" => "codigo.gguf",
              "usage" => ["chat"],
              "capabilities" => ["code", "reasoning"]
            }
          }
        })

      model = elem(Store.get_model(:codigo), 1)

      assert model.usage == [:chat]
      assert model.capabilities == [:code, :reasoning]
    end

    test "las dos formas juntas: usage sin capacidades y capabilities aparte" do
      %{models: [:codigo]} =
        Hydrate.hydrate(%{
          "model" => %{
            "codigo" => %{
              "type" => "local",
              "engine" => "nope",
              "model_dir" => "/modelos",
              "filename" => "codigo.gguf",
              "usage" => ["chat", "completion"],
              "capabilities" => ["code"]
            }
          }
        })

      model = elem(Store.get_model(:codigo), 1)

      assert model.usage == [:chat, :completion]
      assert model.capabilities == [:code]
    end
  end

  describe "split_usage/1 con valores raros" do
    # `to_string/1` sobre un mapa es un `Protocol.UndefinedError`. Como
    # `split_usage/1` es publica, que reventara con un stack trace no ayuda a
    # quien tiene un `usage` raro: ayuda un mensaje que diga que paso.
    test "un mapa no revienta, vuelve como invalido" do
      assert {[], [], ["%{\"chatt\" => 1}"]} = Model.split_usage([%{"chatt" => 1}])
    end

    test "un numero tampoco" do
      assert {[], [], ["123"]} = Model.split_usage([123])
    end

    test "algo que no es una lista" do
      assert {[], [], ["no es lista"]} = Model.split_usage("no es lista")
    end

    test "la lista vacia no es un error" do
      assert {[], [], []} = Model.split_usage([])
    end

    test "los atomos tambien valen, que es como se construye un %Model{}" do
      assert {[:chat], [:reasoning], []} = Model.split_usage([:chat, :reasoning])
    end
  end

  describe "el aviso solo avisa de lo que vino de usage" do
    # El aviso de migracion recorria la lista de capacidades **ya unida**, que
    # incluye lo que el usuario escribio en `capabilities`. O sea: decia
    # «migra esto a capabilities» de algo que ya estaba en `capabilities`.
    #
    # Suena a tonto escrito, y lo es. Pero es el aviso que mas se lee del
    # arranque, y el que hace ir a mirar el toml a quien no deberia.
    import ExUnit.CaptureLog

    test "quien escribe capabilities bien no recibe ni un aviso" do
      log =
        capture_log(fn ->
          assert %{models: [:codigo]} =
                   Hydrate.hydrate(%{
                     "model" => %{
                       "codigo" => %{
                         "type" => "local",
                         "engine" => "nope",
                         "model_dir" => "/modelos",
                         "filename" => "codigo.gguf",
                         "usage" => ["chat"],
                         "capabilities" => ["vision", "reasoning"]
                       }
                     }
                   })
        end)

      # Que el log salga **vacio** es lo que hay que afirmar: no hay nada que
      # migrar. Y esto no es un test que pasa por no mirar nada, porque el test
      # de abajo comprueba que `capture_log` si recoge un aviso de verdad: si
      # `capture_log` no funcionara, ese otro fallaria.
      assert log == "", "avisa de migrar algo que ya esta en capabilities: #{inspect(log)}"

      model = elem(Store.get_model(:codigo), 1)
      assert model.usage == [:chat]
      assert model.capabilities == [:vision, :reasoning]
    end

    test "y quien lo tiene en usage, si" do
      log =
        capture_log(fn ->
          Hydrate.hydrate(%{
            "model" => %{
              "codigo" => %{
                "type" => "local",
                "engine" => "nope",
                "model_dir" => "/modelos",
                "filename" => "codigo.gguf",
                "usage" => ["chat", "code"]
              }
            }
          })
        end)

      assert log =~ "code"
      assert log =~ "Migra a"
    end
  end

  describe "el catalogo real, sin tocar" do
    test "las cuatro combinaciones de usage del catalogo siguen arrancando" do
      # Estas son las que hay en `~/.config/candil/candil.toml` el 2026-10-14.
      # Si el dia que estas cadenas dejen de arrancar, alguien cambio el formato
      # y no aviso.
      for usage <- [
            ["chat", "code", "completion"],
            ["chat", "reasoning"],
            ["chat", "completion"],
            ["embeddings"]
          ] do
        assert %{models: [:codigo]} = hydrate_model(usage), inspect(usage)
      end
    end
  end
end
