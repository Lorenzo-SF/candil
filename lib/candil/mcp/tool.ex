defmodule Candil.MCP.Tool do
  @moduledoc """
  The behaviour a third-party tool implements to be served by Candil's MCP
  server without Candil knowing anything about it.

  ## El criterio de aceptación

  Un tercero define un módulo con este behaviour, lo registra, y `tools/list`
  lo devuelve y `tools/call` lo ejecuta — sin tocar `lib/candil/`. Ese es el
  test que decide si la fase 7 está hecha.
  """

  @doc "The tool's name, as the host sees it."
  @callback name() :: String.t()

  @doc "A short description for the host."
  @callback description() :: String.t()

  @doc "The JSON Schema of the arguments."
  @callback schema() :: map()

  @doc "Runs the tool with the given arguments."
  @callback call(args :: map()) :: term()

  @doc """
  Registers a tool module so the server exposes it.

  The module must implement this behaviour. Registration is idempotent: a
  second registration replaces the first.
  """
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    alias Candil.Tool

    tool = %Tool{
      name: module.name(),
      description: module.description(),
      schema: module.schema(),
      function: fn args -> module.call(args) end
    }

    Tool.define(tool)
  end
end
