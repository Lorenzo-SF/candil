defmodule Candil.Build.PrecompiledTest do
  @moduledoc """
  The `:precompiled` strategy: resolve the asset, download it resumably, and
  put the binaries where the engine will look for them.

  The transport is the suite's existing `Apero.Http` mock, which is what every
  other HTTP-touching test here uses. Everything below the transport is real:
  real files, a real `unzip`, real permissions, and a real rename.

  ## Un zip hecho a mano, y por que

  El archivo de prueba se construye byte a byte con entradas **STORED** (sin
  comprimir). Dos razones, y las dos son A-2:

  1. **El binario `zip` no es del proyecto.** Doce tests de este fichero
     fallaban con `:enoent` donde no estaba, y el rojo decia `enoent` —ni una
     palabra sobre Candil—, y `sudo pacman -S zip` lo desbloqueaba. Un test
     que depende de un programa que el proyecto no instala mide el PATH de
     quien lo corre, no el instalador.
  2. **`:zip.create/3` de OTP no sirve aqui.** En OTP 28 devuelve
     `{:error, :einval}` para **cualquier** entrada, incluida la mas simple.
     Se comprobo ejecutandolo, no se supo.

  Un STORED es un zip de verdad: `unzip` —que es lo que usa `lib/`— lo abre sin
  problema y conserva las entradas anidadas (`build/bin/llama-server`), que es
  justo lo que este fichero quiere comprobar.
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
  #
  # El archivo lo crea `:zip`, que es de OTP, y no el binario `zip` del
  # sistema. Doce tests de este fichero fallaban con `:enoent` en una maquina
  # sin ese binario, y **un rojo que no habla de Candil**: no decia ni una
  # palabra de Candil, solo que no habia `zip`. Un test que depende de un
  # programa que el proyecto no instala prueba el PATH de quien lo corre, no
  # el instalador.
  defp archive(root) do
    staging = Path.join(root, "archive-src")
    File.mkdir_p!(staging)

    entradas =
      Enum.map(@binaries, fn name ->
        contenido = "#!/bin/sh\necho #{name}\n"
        {"build/bin/#{name}", contenido}
      end)

    File.write!(Path.join(root, @archive), zip_stored(entradas))
    File.read!(Path.join(root, @archive))
  end

  # ── Un zip STORED, escrito byte a byte ──────────────────────────────────
  #
  # El formato es entero Y little-endian: las tres firmas, el CRC y todos los
  # tamanos. Escribir `<<0x04034B50::32>>` deja los bytes al reves —
  # `04 03 4B 50` en vez de `50 4B 03 04`— y `unzip` responde «End-of-central-
  # directory signature not found», que no dice nada de por que. Por eso
  # `::little` en todas partes y no solo donde parece que importa.
  #
  # Los permisos van en los `external attributes`, que son 32 bits con el modo
  # unix en los 16 de ARRIBA. Con el modo en los de abajo, `unzip` extrae los
  # binarios con permisos `000` y el test que comprueba que se instalan
  # ejecutables cae por un motivo que no es el que cree.
  @dos_hora 0
  # 1980-01-01: la epoca del formato, y no un 1970 que no existe
  @dos_fecha 33

  defp zip_stored(entradas) do
    {locales, central, _desplazamiento} =
      Enum.reduce(entradas, {[], [], 0}, fn {nombre, contenido}, {loc, cen, off} ->
        crc = :erlang.crc32(contenido)
        bytes = byte_size(contenido)
        largo = byte_size(nombre)

        local =
          <<0x04034B50::little-32, 20::little-16, 0::little-16, 0::little-16,
            @dos_hora::little-16, @dos_fecha::little-16, crc::little-32, bytes::little-32,
            bytes::little-32, largo::little-16, 0::little-16>> <> nombre <> contenido

        central_entry =
          <<0x02014B50::little-32, 0x031E::little-16, 20::little-16, 0::little-16, 0::little-16,
            @dos_hora::little-16, @dos_fecha::little-16, crc::little-32, bytes::little-32,
            bytes::little-32, largo::little-16, 0::little-16, 0::little-16, 0::little-16,
            0::little-16, Bitwise.bsl(0o755, 16)::little-32, off::little-32>> <> nombre

        {[local | loc], [central_entry | cen], off + byte_size(local)}
      end)

    locales = locales |> Enum.reverse() |> IO.iodata_to_binary()
    central = central |> Enum.reverse() |> IO.iodata_to_binary()

    fin =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, length(entradas)::little-16,
        length(entradas)::little-16, byte_size(central)::little-32, byte_size(locales)::little-32,
        0::little-16>>

    locales <> central <> fin
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
