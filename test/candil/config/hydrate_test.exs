defmodule Candil.Config.HydrateTest do
  use ExUnit.Case, async: false

  alias Candil.{Build, Model, Source, Store}
  alias Candil.Config.{File, Hydrate}

  @ropero Path.expand("../../../proyecto 4.0/candil.toml", __DIR__)

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

  describe "the real ropero configuration" do
    test "every section registers without a single error" do
      result = Hydrate.hydrate(load!())

      assert result.engines == [:llama_cpp]
      assert result.providers == [:openai]

      assert result.models == [
               :analyst,
               :coder,
               :coder_lite,
               :designer,
               :embed,
               :gpt4o,
               :verifier
             ]
    end

    test "the models land in the Store" do
      Hydrate.hydrate(load!())

      assert 7 = length(Store.list_models())
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
      assert Model.file_path(coder) =~ "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
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
      assert "-DCMAKE_CUDA_ARCHITECTURES=120a" in engine.install.cmake_args
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

      assert {:ok, analyst} = Store.get_model(:analyst)
      assert analyst.draft.kind == :huggingface
      assert Source.dest_path(analyst.draft) =~ "mtp-Qwen3.8-27B-Q4_0.gguf"
      refute Source.dest_path(analyst.draft) =~ "~"
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
end
