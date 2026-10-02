defmodule Candil.Engine.Launcher.Http do
  @moduledoc ~S"""
  Attaches to an engine somebody else is already running.

  This is the reference implementation of `Candil.Engine.Launcher`, and the
  reason that behaviour exists. With it, vLLM, text-generation-inference,
  LM Studio, Ollama, airllm, tensorrt-llm and mlx-lm are all covered by
  writing zero lines each: they all speak the OpenAI-compatible API, and the
  only thing that ever differed between them was who started the process.

  ## `pid: nil`, and why it is not an oversight

  ```elixir
  def launch(%Engine{host: host, port: port}, %Model{}) do
    {:ok, %{base_url: "http://#{host}:#{port}", pid: nil}}
  end
  ```

  The pid is `nil` because the process is **not ours**. `Engine.stop/1` on an
  external engine unregisters the Candil-side GenServer and sends nothing: the
  server was somebody else's, and it is still somebody else's when we leave.

  Get that wrong in the other direction — a launcher that returns a pid it did
  not start — and `candil stop` kills a shared service that other people were
  using. `pid: nil` is the whole safety property of this module.

  ## Example


  ```toml
  [engine.tgi]
  binary    = "ignored-by-the-http-launcher"
  host      = "10.0.0.5"
  port      = 8080
  launcher  = Candil.Engine.Launcher.Http
  ```

      $ ./candil run tgi
      ✓ tgi enganchado a http://10.0.0.5:8080 (externo, no gestionado)
      $ ./candil stop tgi
      ✓ tgi desconectado (el proceso sigue vivo: no es nuestro)
  """

  @behaviour Candil.Engine.Launcher

  alias Candil.{Engine, Model}

  @impl true
  @spec launch(Engine.t(), Model.t()) ::
          {:ok, %{base_url: binary(), pid: nil}} | {:error, term()}
  def launch(%Engine{host: host, port: port}, %Model{}) do
    {:ok, %{base_url: "http://#{host}:#{port}", pid: nil}}
  end

  @doc """
  Why there is nothing to tear down.
  """
  @spec owns_process?() :: false
  def owns_process?, do: false
end
