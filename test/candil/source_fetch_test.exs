defmodule Candil.SourceFetchTest do
  @moduledoc """
  The download path, exercised against a real local HTTP server.

  Everything here would pass just as well against a mock, and prove nothing.
  The properties that matter — resume, streaming checksum, atomic rename —
  are all properties of how bytes hit a socket and a filesystem.
  """

  use ExUnit.Case, async: false

  alias Candil.Source
  alias Plug.Conn

  @payload :crypto.strong_rand_bytes(64 * 1024)
  @digest Base.encode16(:crypto.hash(:sha256, @payload), case: :lower)

  setup do
    # Other test modules put :apero's http_adapter to a Mox mock and set it
    # globally. This suite talks to a real socket, so the real adapter goes
    # back — otherwise a passing download path is a mock returning bytes.
    previous = Application.get_env(:apero, :http_adapter)
    Application.put_env(:apero, :http_adapter, Apero.Http.Adapter.Finch)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apero, :http_adapter, previous),
        else: Application.delete_env(:apero, :http_adapter)
    end)

    server =
      start_supervised!(
        {Bandit, port: 0, plug: {__MODULE__.Handler, %{payload: @payload}}},
        id: :candil_source_fetch_server
      )

    %{port: port} = server_info(server)

    {:ok, dir: dir} = tmp_dir()
    on_exit(fn -> File.rm_rf(dir) end)

    %{server: server, port: port, dir: dir}
  end

  defp server_info(server) do
    # Bandit exposes the bound port via the listener info.
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  defp tmp_dir do
    dir =
      Path.join([
        System.tmp_dir!(),
        "candil-source-fetch-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  # `dest` on a Source is the DIRECTORY, not the full path. The file name
  # comes from the URL. Getting those two confused is the first thing that
  # goes wrong when writing a download by hand.
  defp url_source(port, opts \\ []) do
    %Source{
      kind: :url,
      url: "http://127.0.0.1:#{port}/model.gguf",
      dest: opts[:dir] || System.tmp_dir!(),
      sha256: opts[:sha256]
    }
  end

  describe "a complete download" do
    test "lands at the destination with the right bytes", ctx do
      source = url_source(ctx.port, dir: ctx.dir)

      assert {:ok, path} = Source.fetch(source)
      assert path == Source.dest_path(source)
      assert File.read!(path) == @payload
    end

    test "leaves no .part behind", ctx do
      source = url_source(ctx.port, dir: ctx.dir)
      assert {:ok, path} = Source.fetch(source)
      refute File.exists?(path <> ".part")
    end

    test "is idempotent: a second call does not re-download", ctx do
      source = url_source(ctx.port, dir: ctx.dir)
      assert {:ok, path} = Source.fetch(source)
      mtime = File.stat!(path).mtime

      assert {:ok, ^path} = Source.fetch(source)
      assert File.stat!(path).mtime == mtime
    end

    test "verifies the checksum while streaming, with no second pass", ctx do
      source = url_source(ctx.port, dir: ctx.dir, sha256: @digest)
      assert {:ok, _path} = Source.fetch(source)
    end
  end

  describe "a checksum mismatch" do
    test "is refused and the partial file is removed", ctx do
      source = url_source(ctx.port, dir: ctx.dir, sha256: String.duplicate("0", 64))

      assert {:error, %Candil.Error{reason: :invalid_request} = error} = Source.fetch(source)
      assert Exception.message(error) =~ "checksum mismatch"

      # A mismatching file left on disk is worse than no file: every
      # existence check says it is there.
      refute File.exists?(Source.dest_path(source))
      refute File.exists?(Source.dest_path(source) <> ".part")
    end
  end

  describe "resume" do
    test "continues a partial .part instead of starting over", ctx do
      source = url_source(ctx.port, dir: ctx.dir)
      dest = Source.dest_path(source)
      half = div(byte_size(@payload), 2)

      # Simulate an interrupted transfer: the first half is on disk.
      File.write!(dest <> ".part", binary_part(@payload, 0, half))
      assert {:ok, 0} = Source.progress(source)

      assert {:ok, ^dest} = Source.fetch(source)
      assert File.read!(dest) == @payload
    end

    test "a resumed download still verifies against the whole file", ctx do
      # Seeding the digest with only the newly-received bytes would pass the
      # wrong checksum roughly never. This is the one that would have been
      # missed by a test that only checked the final bytes.
      source = url_source(ctx.port, dir: ctx.dir, sha256: @digest)
      dest = Source.dest_path(source)
      half = div(byte_size(@payload), 2)
      File.write!(dest <> ".part", binary_part(@payload, 0, half))

      assert {:ok, _} = Source.fetch(source)
    end

    test "a corrupt .part is caught by the checksum", ctx do
      source = url_source(ctx.port, dir: ctx.dir, sha256: @digest)
      dest = Source.dest_path(source)

      File.write!(dest <> ".part", :crypto.strong_rand_bytes(1024))

      assert {:error, %Candil.Error{}} = Source.fetch(source)
      refute File.exists?(dest)
    end
  end

  describe "progress/1" do
    test "reads the bytes in flight from another process", ctx do
      source = url_source(ctx.port, dir: ctx.dir)
      dest = Source.dest_path(source)
      File.write!(dest <> ".part", binary_part(@payload, 0, 4096))

      Source.fetch(source)

      # Cleared on success, so a caller polling does not see a stale total.
      assert {:ok, 0} = Source.progress(source)
    end

    test "is zero for something that was never downloaded", ctx do
      assert {:ok, 0} = Source.progress(url_source(ctx.port, dir: ctx.dir))
    end
  end

  describe "dest_name" do
    test "flattens a repo subdirectory", ctx do
      source = %Source{
        kind: :url,
        url: "http://127.0.0.1:#{ctx.port}/model.gguf",
        dest: ctx.dir,
        dest_name: "flat.gguf"
      }

      assert {:ok, path} = Source.fetch(source)
      assert Path.basename(path) == "flat.gguf"
    end
  end

  defmodule Handler do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, %{payload: payload}) do
      {:cont, respond(conn, payload), :ok}
    end

    defp respond(conn, payload) do
      # req_headers is a list of {binary, binary} tuples. get_in/2 with a
      # string key raises "the Access module supports only keyword lists".
      case List.keyfind(conn.req_headers, "range", 0) do
        nil ->
          conn
          |> Conn.put_resp_content_type("application/octet-stream")
          |> Conn.send_resp(200, payload)

        {_, "bytes=" <> range} ->
          # "bytes=N-" means "from N to the end", which is what a resume asks
          # for. A client does not have to know the total size in advance.
          {start, stop} =
            case String.split(range, "-") do
              [from, ""] -> {String.to_integer(from), byte_size(payload) - 1}
              [from, to] -> {String.to_integer(from), String.to_integer(to)}
            end

          conn
          |> Conn.put_resp_header(
            "content-range",
            "bytes #{start}-#{stop}/#{byte_size(payload)}"
          )
          |> Conn.put_resp_content_type("application/octet-stream")
          |> Conn.send_resp(206, binary_part(payload, start, stop - start + 1))
      end
    end
  end
end
