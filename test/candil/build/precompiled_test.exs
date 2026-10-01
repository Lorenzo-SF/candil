defmodule Candil.Build.PrecompiledTest do
  @moduledoc """
  The `:precompiled` strategy: resolve the asset, download it resumably, and
  put the binaries where the engine will look for them.

  The transport is the suite's existing `Apero.Http` mock, which is what every
  other HTTP-touching test here uses. Everything below the transport is real:
  real files, a real `unzip`, real permissions, and a real rename.
  """

  use ExUnit.Case, async: false
  import Mox

  alias Apero.Http.Request
  alias Candil.{Build, HTTPAdapterMock}

  @binaries ["llama-server", "llama-cli"]
  @archive "llama-b4561-bin-ubuntu-x64.zip"
  @url "https://example.test/" <> @archive

  setup :verify_on_exit!

  setup do
    Application.put_env(:apero, :http_adapter, HTTPAdapterMock)

    root = Path.join(System.tmp_dir!(), "candil-pre-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, dir: Path.join(root, "bin")}
  end

  defp plan(dir, overrides \\ []) do
    attrs =
      Keyword.merge(
        [strategy: :precompiled, dir: dir, binaries: @binaries, sha256: nil, version: "b4561"],
        overrides
      )

    {:ok, build} = Build.new(attrs)
    build
  end

  # A real zip, nested the way a llama.cpp release archive is nested, because
  # assuming `llama-server` sits at the root is how the layout change in a
  # future release turns into a silent "installed nothing".
  defp archive(root) do
    staging = Path.join(root, "archive-src")
    File.mkdir_p!(Path.join(staging, "build/bin"))

    for name <- @binaries do
      File.write!(Path.join([staging, "build/bin", name]), "#!/bin/sh\necho #{name}\n")
    end

    path = Path.join(root, @archive)
    {_out, 0} = System.cmd("zip", ["-q", "-r", path, "."], cd: staging, stderr_to_stdout: true)
    File.read!(path)
  end

  # The stream callback answers with `{:cont, acc}` or `{:halt, acc}`, so a
  # helper that just threaded `acc` would feed the tuple back in on the next
  # event.
  defp feed(fun, acc, event) do
    case fun.(event, acc) do
      {:cont, acc} -> acc
      {:halt, acc} -> acc
    end
  end

  # Serves a response through the mocked adapter: status, then body, then the
  # event that ends the stream.
  defp serve(status, body, me) do
    expect(HTTPAdapterMock, :stream, fn %Request{method: :get} = request, acc, fun, _opts ->
      send(me, {:requested, request.headers})
      acc = feed(fun, acc, {:status, status})
      acc = feed(fun, acc, {:headers, [{"content-length", Integer.to_string(byte_size(body))}]})
      acc = feed(fun, acc, {:data, body})
      acc = feed(fun, acc, {:done, :done})
      {:ok, acc}
    end)
  end

  # Stands in for a server that ignored our Range and sent the whole file.
  defp serve_ignoring_range(body, me) do
    expect(HTTPAdapterMock, :stream, fn %Request{}, acc, fun, _opts ->
      send(me, {:requested, []})
      acc = feed(fun, acc, {:status, 200})
      acc = feed(fun, acc, {:data, body})
      acc = feed(fun, acc, {:done, :done})
      {:ok, acc}
    end)
  end

  # The name the download derives from the URL, so a test that seeds a partial
  # file seeds the one install/2 will actually look for.
  defp part_path(dir), do: Path.join(dir, @archive <> ".part")

  defp installed?(dir, name) do
    path = Path.join(dir, name)

    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  describe "install/2" do
    test "downloads, unpacks, and leaves the binaries executable", %{root: root, dir: dir} do
      serve(200, archive(root), self())
      build = plan(dir)

      assert {:ok, %{path: path}} = Build.install(build, asset_url: @url)
      assert path == Path.expand(dir)

      for name <- @binaries do
        assert installed?(dir, name), "#{name} is not installed and executable"
      end
    end

    test "check/1 is :ok afterwards", %{root: root, dir: dir} do
      serve(200, archive(root), self())
      build = plan(dir)

      assert {:ok, _} = Build.install(build, asset_url: @url)
      assert :ok = Build.check(build)
    end

    test "the archive is renamed into place and no .part is left", %{root: root, dir: dir} do
      serve(200, archive(root), self())
      build = plan(dir)

      assert {:ok, _} = Build.install(build, asset_url: @url)

      assert File.exists?(Path.join(dir, @archive))
      refute File.exists?(part_path(dir))
    end

    test "nothing on disk survives a failure that stops before the rename", %{dir: dir} do
      serve(404, "", self())
      build = plan(dir, binaries: [])

      assert {:error, message} = Build.install(build, asset_url: @url)
      assert message =~ "404"
      refute File.exists?(Path.join(dir, @archive))
    end

    test "an asset_url is used as given, with no call to GitHub", %{root: root, dir: dir} do
      serve(200, archive(root), self())
      build = plan(dir)

      # No Detector expectation is set: reaching for the release API at all
      # would fail the mock verification.
      assert {:ok, _} = Build.install(build, asset_url: @url)
      assert_received {:requested, headers}
      assert headers == []
    end
  end

  describe "checksum" do
    test "a matching sha256 lets the archive through", %{root: root, dir: dir} do
      body = archive(root)
      serve(200, body, self())
      build = plan(dir, sha256: sha256(body))

      assert {:ok, _} = Build.install(build, asset_url: @url)
    end

    test "a mismatch is an error and nothing is renamed into place", %{root: root, dir: dir} do
      serve(200, archive(root), self())
      build = plan(dir, sha256: String.duplicate("0", 64))

      assert {:error, message} = Build.install(build, asset_url: @url)
      assert message =~ "SHA-256 mismatch"
      refute File.exists?(Path.join(dir, @archive))
    end

    test "the hash is folded in as the bytes go past, not by reading the file back",
         %{root: root, dir: dir} do
      body = archive(root)
      serve(200, body, self())

      build = plan(dir, sha256: sha256(body))
      assert {:ok, _} = Build.install(build, asset_url: @url)

      # The file on disk is the archive, and it hashes to the same thing. A
      # whole-file `File.read/1` would have produced the same answer here, so
      # this test is the floor, not the ceiling: what it rules out is a
      # checksum that only ever matched for a file small enough to slurp.
      assert sha256(File.read!(Path.join(dir, @archive))) == sha256(body)
    end
  end

  describe "resuming" do
    test "an existing .part is continued with a Range request", %{root: root, dir: dir} do
      body = archive(root)
      {head, tail} = String.split_at(body, 40)

      File.mkdir_p!(dir)
      File.write!(part_path(dir), head)

      serve(206, tail, self())
      build = plan(dir, sha256: sha256(body))

      assert {:ok, _} = Build.install(build, asset_url: @url)
      assert_received {:requested, headers}
      assert [{"range", "bytes=#{byte_size(head)}-"}] == headers
    end

    test "the resumed file is the whole file, not the tail", %{root: root, dir: dir} do
      body = archive(root)
      {head, tail} = String.split_at(body, 40)

      File.mkdir_p!(dir)
      File.write!(part_path(dir), head)

      serve(206, tail, self())
      build = plan(dir, sha256: sha256(body))

      assert {:ok, _} = Build.install(build, asset_url: @url)
      assert File.read!(Path.join(dir, @archive)) == body
    end

    test "the checksum still covers the bytes that were already on disk", %{root: root, dir: dir} do
      # The hash state cannot be carried across a request, so the partial file
      # has to be folded back in. Getting this wrong yields a correct archive
      # with a checksum computed over half of it.
      body = archive(root)
      {head, tail} = String.split_at(body, 40)

      File.mkdir_p!(dir)
      File.write!(part_path(dir), head)

      serve(206, tail, self())
      build = plan(dir, sha256: sha256(body))

      assert {:ok, _} = Build.install(build, asset_url: @url)
    end

    test "a server that ignores the Range is refused, not appended to", %{root: root, dir: dir} do
      body = archive(root)
      {head, _tail} = String.split_at(body, 40)

      File.mkdir_p!(dir)
      File.write!(part_path(dir), head)

      serve_ignoring_range(body, self())
      build = plan(dir, binaries: [])

      assert {:error, message} = Build.install(build, asset_url: @url)
      assert message =~ "200"
      assert message =~ "resumed from byte"

      # The corrupt concatenation stays a .part. It is not promoted.
      refute File.exists?(Path.join(dir, @archive))
    end

    test "a fresh download sends no Range header", %{root: root, dir: dir} do
      serve(200, archive(root), self())
      build = plan(dir)

      assert {:ok, _} = Build.install(build, asset_url: @url)
      assert_received {:requested, []}
    end
  end

  defp sha256(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end
end
