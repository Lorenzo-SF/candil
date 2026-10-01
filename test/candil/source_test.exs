defmodule Candil.SourceTest do
  use ExUnit.Case, async: true

  alias Candil.Error
  alias Candil.Source

  doctest Candil.Source

  @hf %Source{
    kind: :huggingface,
    repo: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
    file: "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf",
    dest: "/models"
  }

  describe "new/1" do
    test "builds a valid huggingface source" do
      assert {:ok, %Source{kind: :huggingface, repo: "user/repo"}} =
               Source.new(kind: :huggingface, repo: "user/repo", file: "m.gguf", dest: "/m")
    end

    test "lists every missing field rather than only the first" do
      assert {:error, errors} = Source.new(kind: :huggingface)
      assert "repo is required" in errors
      assert "file is required" in errors
      assert "dest is required" in errors
    end

    test "rejects an unknown kind" do
      assert {:error, ["kind must be :huggingface, :url or :local, got: :ftp"]} =
               Source.new(kind: :ftp, dest: "/m")
    end

    test "treats an empty string as missing" do
      assert {:error, ["file is required"]} =
               Source.new(kind: :huggingface, repo: "u/r", file: "", dest: "/m")
    end
  end

  describe "url/1" do
    test "resolves a huggingface repo and file to an HTTPS URL" do
      assert Source.url(@hf) ==
               "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
    end

    test "honours an explicit revision" do
      assert Source.url(%{@hf | revision: "b4561"}) =~ "/resolve/b4561/"
    end

    test "defaults a nil revision to main" do
      assert Source.url(%{@hf | revision: nil}) =~ "/resolve/main/"
    end

    test "passes a direct url through" do
      assert Source.url(%Source{kind: :url, url: "https://example.com/m.gguf"}) ==
               "https://example.com/m.gguf"
    end

    test "is nil for a local source" do
      assert Source.url(%Source{kind: :local, path: "/m/m.gguf"}) == nil
    end
  end

  describe "filename/1" do
    test "is the basename of the repo file" do
      assert Source.filename(@hf) == "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
    end

    test "dest_name wins over the repo file name" do
      assert Source.filename(%{@hf | dest_name: "mtp.gguf"}) == "mtp.gguf"
    end

    test "flattens a repo subdirectory, which is what hf leaves behind" do
      # ropero had to copy this file out of MTP/ by hand after every download.
      source = %Source{
        kind: :huggingface,
        repo: "u/r",
        file: "MTP/mtp-Qwen3-Q4_0.gguf",
        dest: "/m"
      }

      assert Source.filename(source) == "mtp-Qwen3-Q4_0.gguf"
    end

    test "takes the last path segment of a direct url" do
      assert Source.filename(%Source{kind: :url, url: "https://x.io/a/b/model.gguf"}) ==
               "model.gguf"
    end

    test "is the basename of a local path" do
      assert Source.filename(%Source{kind: :local, path: "/models/x/model.gguf"}) == "model.gguf"
    end
  end

  describe "dest_path/1" do
    test "joins the expanded dest with the filename" do
      assert Source.dest_path(%{@hf | dest: "/models"}) ==
               "/models/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
    end

    test "expands ~ so no argument ever carries a literal tilde" do
      # `~` is not expanded inside a quoted argument, so a path reaching a
      # spawned process would be a directory literally named `~`.
      path = Source.dest_path(%{@hf | dest: "~/.candil/models"})
      assert String.starts_with?(path, "/")
      refute String.contains?(path, "~")
    end

    test "is nil for a local source" do
      assert Source.dest_path(%Source{kind: :local, path: "/m/x.gguf"}) == nil
    end

    test "is nil when dest is unset" do
      assert Source.dest_path(%{@hf | dest: nil}) == nil
    end
  end

  describe "present?/1 and size/1" do
    @tag :tmp_dir
    test "sees a real file and reports its size", %{tmp_dir: dir} do
      path = Path.join(dir, "m.gguf")
      File.write!(path, "0123456789")
      source = %Source{kind: :huggingface, repo: "u/r", file: "m.gguf", dest: dir}
      assert Source.present?(source)
      assert Source.size(source) == 10
    end

    @tag :tmp_dir
    test "treats an empty file as not present", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "m.gguf"), "")
      source = %Source{kind: :huggingface, repo: "u/r", file: "m.gguf", dest: dir}
      refute Source.present?(source)
    end

    test "is false when nothing is there" do
      refute Source.present?(%{@hf | dest: "/nonexistent-candil-test-dir"})
    end

    test "a local source is present when the file exists" do
      assert Source.present?(%Source{kind: :local, path: __ENV__.file}) == true
    end
  end

  describe "contract stubs" do
    test "fetch/2 returns an error that names the function, not an exception" do
      assert {:error, %Error{reason: :not_implemented, context: context}} =
               Source.fetch(@hf)

      assert context.function == "Candil.Source.fetch/2"
      assert context.phase == 1
    end

    test "progress/1 behaves the same way" do
      assert {:error,
              %Error{reason: :not_implemented, context: %{function: "Candil.Source.progress/1"}}} =
               Source.progress(@hf)
    end

    test "the stubs honour their own spec, which is what keeps dialyzer quiet" do
      # A stub that raises is `none()` to dialyzer and reports
      # invalid_contract, so the contract-first stubs all need a warning
      # filter. Returning the error keeps the spec truthful instead.
      assert {:error, %Error{}} = Source.fetch(@hf)
    end
  end
end
