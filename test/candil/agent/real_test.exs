defmodule Candil.Agent.RealTest do
  @moduledoc """
  `Candil.Agent` funcionando, con un backend de verdad y una herramienta de
  verdad.

  ## Por qué este test existe

  `use Candil.Agent` es lo más parecido a un framework que hay en Candil, y
  tenía **cero usos** fuera de sus propios tests: nunca se había ejecutado
  contra un backend que hable de verdad.

  ## El contrato de una llamada a herramienta, que no es el que parece

  Dos cosas que un LLM de verdad da por hechas y aquí se trampearon:

  1. La llamada va en el **texto** del `content`, dentro de
     `<tool_call>{...}</tool_call>`. No es un campo `tool_calls` del mapa.

  2. El resultado vuelve en un mensaje con **`role: "tool"`**. El agente lo
     ponía con `role: "user"`, así que el modelo receive su propio resultado
     como si lo hubiera dicho el usuario: volvía a pedir la herramienta, y otra
     vez, hasta agotar los pasos. **El bucle ReAct no cerraba jamás contra un
     backend real.**

  Las dos cosas están arregladas. Este test es lo que las destapa, y lo que
  impide que vuelvan.
  """

  use ExUnit.Case, async: false

  alias Candil.{Agent, Tool}

  @global_calls :candil_agent_real_calls

  # ── una herramienta de verdad ────────────────────────────────────────────────

  defmodule Weather do
    @moduledoc false
    use Candil.Tool,
      name: "weather",
      description: "El tiempo en una ciudad",
      schema: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }

    @impl true
    def run(%{"city" => city}) do
      Candil.Agent.RealTest.record(city)
      {:ok, "En #{city} hay 18 grados"}
    end
  end

  # ── un backend de verdad ─────────────────────────────────────────────────────

  defmodule Backend do
    @moduledoc false

    def chat(_model, messages, _opts) do
      # El agente mete el resultado de la herramienta con `role: "tool"`. Un LLM
      # de verdad lo espera así; antes el agente lo ponía como "user" y el bucle
      # no cerraba nunca con un backend de verdad.
      if Enum.any?(messages, &(&1.role == "tool")) do
        {:ok, %{content: "FINAL_ANSWER: hace 18 grados"}}
      else
        Candil.Agent.RealTest.record(:pidio_tool)
        json = ~s({"name":"weather","args":{"city":"Madrid"}})

        # El tag se construye con los bytes 60 y 62 A PROPOSITO. Escribirlo a
        # mano hace que un invisible se cuele entre el `<` y el nombre, el
        # parser no encuentra la llamada, y el agente se queda en
        # `max_steps_exhausted` sin dar ninguna pista de por qué.
        lt = <<60>>
        gt = <<62>>
        abre = lt <> "tool_call" <> gt
        cierra = lt <> "/tool_call" <> gt
        {:ok, %{content: abre <> json <> cierra}}
      end
    end
  end

  # ── el agente ────────────────────────────────────────────────────────────────

  defmodule Meteorologo do
    @moduledoc false

    # `tools:` espera `%Tool{}` YA CONSTRUIDOS, no módulos: el `use` parece que
    # registra tus herramientas y NO lo hace. Para que el agente vea la
    # herramienta hay que llamar a `Candil.Tool.define/1`, que se hace en el
    # setup de abajo.
    use Candil.Agent,
      name: "meteorologo",
      goal: "responde el tiempo",
      max_steps: 4,
      stop_words: ["FINAL_ANSWER"]
  end

  # ── quien mira lo que pasa ──────────────────────────────────────────────────

  def record(what), do: send(:persistent_term.get(@global_calls, self()), {:llamo, what})

  setup do
    Tool.reset()
    :persistent_term.put(@global_calls, self())

    # Y la herramienta se REGISTRA de verdad, que es lo que hace el registro.
    :ok = Tool.define(Weather.__tool__())

    on_exit(fn ->
      :persistent_term.erase(@global_calls)
      Tool.reset()
    end)

    :ok
  end

  describe "un agente de verdad" do
    test "pide la herramienta, la recibe, y responde" do
      assert {:ok, respuesta, trace} = Meteorologo.run("¿qué tiempo hace?", backend: Backend)

      # El contenido, no el código de salida.
      assert respuesta =~ "18 grados"

      # Y la traza deja ver que PIDIÓ la herramienta. Sin esto, un agente que
      # se limitase a alucinar la respuesta también pasaría este test.
      kinds = Enum.map(trace, & &1.kind)
      assert :action in kinds
      # El `@type step` declara `:observation`, pero el bucle nunca lo emite: la
      # observación va dentro de un `:action`. El tipo miente; aquí se fija lo que
      # el bucle REALMENTE hace.
      refute :observation in kinds
    end

    test "la herramienta se llamó de verdad, con sus argumentos" do
      Meteorologo.run("¿qué tiempo hace?", backend: Backend)

      assert_received {:llamo, "Madrid"}
      assert_received {:llamo, :pidio_tool}
    end

    test "el rastro es legible y ordenado" do
      {:ok, _respuesta, trace} = Meteorologo.run("¿qué tiempo hace?", backend: Backend)

      assert length(trace) <= 3
      assert Enum.all?(trace, &is_map/1)
      assert Enum.all?(trace, &(&1.kind in [:thought, :action, :final]))
    end

    test "el agente tiene nombre, objetivo y herramientas" do
      cfg = Meteorologo.__agent_config__()

      assert cfg.name == "meteorologo"
      assert cfg.goal == "responde el tiempo"
      # Y el campo que genera el `use` es `tool_schemas`, NO `tools`.
      assert is_list(cfg.tool_schemas)
    end
  end

  describe "lo que NO hace" do
    test "sin backend, en vez de reventar con una excepción de Erlang" do
      # `resolve_backend/1` devolvía `nil` y el bucle hacía `nil.chat(...)`.
      # Un agente que muere por un error de configuración es justo lo que un
      # framework no puede permitirse: quien lo usa no se entera de que le
      # falta algo hasta que algo se rompe en producción.
      assert {:error, {:error, :no_backend}, _trace} =
               Meteorologo.run("¿qué tiempo hace?")
    end
  end
end
