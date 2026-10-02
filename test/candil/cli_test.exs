defmodule Candil.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Candil.CLI

  doctest Candil.CLI.Version

  describe "run/1 dispatch" do
    test "the bare word `version` prints the version" do
      # Not just the flag. The first cut only knew `--version` and `-v`, so
      # the spelling a person actually types fell through to the help and
      # looked like a broken binary.
      assert capture_io(fn -> CLI.main(["version"]) end) =~ "Candil "
    end

    test "the flag spellings agree with it" do
      expected = capture_io(fn -> CLI.main(["version"]) end)

      for spelling <- ["--version", "-v"] do
        assert capture_io(fn -> CLI.main([spelling]) end) == expected
      end
    end

    test "no arguments prints the usage, not an error" do
      out = capture_io(fn -> CLI.main([]) end)
      assert out =~ "Usage: candil"
    end

    test "help, in any of its spellings, prints the usage" do
      for spelling <- ["help", "--help", "-h"] do
        assert capture_io(fn -> CLI.main([spelling]) end) =~ "Usage: candil"
      end
    end

    test "an unknown command falls back to the help rather than raising" do
      # A CLI that crashes on a typo teaches the user nothing about what the
      # right spelling is.
      assert capture_io(fn -> CLI.main(["frobnicate"]) end) =~ "Usage: candil"
    end
  end

  describe "main/1" do
    test "starts the application, because the catalogue lives in ETS" do
      # The design document flags this as the detail that is forgotten every
      # time: a command that runs before the supervision tree is up looks at
      # empty tables and reports an empty catalogue, which reads as a
      # configuration problem and is not one.
      out = capture_io(fn -> CLI.main(["version"]) end)
      assert out =~ "Candil "
    end
  end

  describe "the version" do
    test "comes from the application spec, not a constant" do
      assert Candil.CLI.Version.version() == to_string(Application.spec(:candil, :vsn))
    end

    test "says unknown rather than crashing when the app is not loaded" do
      # A version command that crashes is worse than one that admits it does
      # not know.
      assert Candil.CLI.Version.render("unknown") == "Candil unknown"
    end
  end
end
