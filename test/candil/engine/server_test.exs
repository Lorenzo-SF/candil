defmodule Candil.Engine.ServerTest do
  use ExUnit.Case, async: true

  # Server is tested indirectly through integration tests.
  # The private build_args/2 has path-traversal defence that raises on
  # `..` in model_dir/filename (defence-in-depth alongside Model.validate).
  # That raise is tested via Model.validate which catches it earlier.
end
