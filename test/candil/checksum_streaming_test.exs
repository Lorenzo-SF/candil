defmodule Candil.ChecksumStreamingTest do
  @moduledoc """
  `Installer.verify_checksum/2` used to be `File.read(path)` followed by
  hashing the binary. For a GGUF that is 17 GB read into memory in one
  allocation, which is an out-of-memory before the download is even verified.
  """

  use ExUnit.Case, async: true

  alias Candil.Installer

  @tag :tmp_dir
  test "hashes a file larger than one block, correctly", %{tmp_dir: dir} do
    # Three blocks plus a remainder, so the loop boundary is exercised.
    payload = :crypto.strong_rand_bytes(1024 * 1024 * 2 + 4321)
    path = Path.join(dir, "model.gguf")
    File.write!(path, payload)

    expected = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

    assert :ok = Installer.verify_checksum(path, expected)
  end

  @tag :tmp_dir
  test "rejects a mismatch and names both digests", %{tmp_dir: dir} do
    path = Path.join(dir, "model.gguf")
    File.write!(path, "contenido")

    assert {:error, message} = Installer.verify_checksum(path, String.duplicate("0", 64))
    assert message =~ "checksum mismatch"
    assert message =~ String.duplicate("0", 8)
  end

  @tag :tmp_dir
  test "accepts the digest in either case", %{tmp_dir: dir} do
    path = Path.join(dir, "m.bin")
    File.write!(path, "abc")

    lower = :crypto.hash(:sha256, "abc") |> Base.encode16(case: :lower)

    assert :ok = Installer.verify_checksum(path, lower)
    assert :ok = Installer.verify_checksum(path, String.upcase(lower))
  end

  @tag :tmp_dir
  test "an empty file hashes to the empty digest, not an error", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.bin")
    File.write!(path, "")

    empty = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    assert :ok = Installer.verify_checksum(path, empty)
  end

  test "a missing file is an error, not a crash" do
    assert {:error, message} =
             Installer.verify_checksum("/no/existe/candil.bin", String.duplicate("0", 64))

    assert message =~ "checksum verification"
  end
end
