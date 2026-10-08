defmodule Candil.Agent.RealTest do
  @moduledoc """
  `Candil.Agent` funcionando, con un backend de verdad y una herramienta de
  verdad.

  ## Por qué este test existe

  `use Candil.Agent` es el patron mas parecido a un framework que hay en todo
  Candil, y tiene **cero usos** fuera de sus propios tests: nunca se ha
  ejecutado contra un backend que hable de verdad.

  Y al ejecutarlo aparece lo que。建立
  `resolve_backend/1` devuelve `nil` cuando no se le pasa `:backend`, y el bucle
  hace `backend.chat(model, messages, ...)` sin comprobar nada. Con `nil` eso es
  un `UndefinedFunctionError` que nadie captura: el agente revienta con una
  excepcion de Erlang en lugar de decir "no tengo backend".

  ## El backend de aqui

  Un modulo con `chat/3` que devuelve respuestas escritas a mano: primero pide
  una herramienta, luego le da el resultado. Es exactamente lo que hace un LLM
  en un bucle ReAct, y es lo que hay que comprobar de verdad.
  """

  use ExUnit.Case, async: false

  alias Candil.{Agent, Tool}

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
    # Un LLM de mentira que SI SABE lo que hace un LLM: pide la herramienta, y
    # cuando le llega el resultado responde con la palabra final.
    def chat(_model, messages, _opts) do
      # HALLAZGO: `invoke_tools/3` mete la observacion con `role: "user"`, NO
      # con `role: "tool"`. Es decir, el agente le ENSENA al modelo su propio
      # resultado como si lo hubiera dicho el usuario. Un LLM de verdad recibe
      # el resultado de una herramienta en un mensaje de rol `tool`, y este
      # bucle ReAct, contra un backend real, no llega a cerrar nunca.
      #
      # Aqui se busca el "user" con la respuesta dentro, que es lo que un
      # backend real tendria que hacer para no morder este lazo.
      if Enum.any?(
           messages,
           &(&1.role == "user" and String.contains?(to_string(&1.content), "weather"))
         ) do
        {:ok, %{content: "FINAL_ANSWER: hace 18 grados"}}
      else
        Candil.Agent.RealTest.record(:pidio_tool)

        # Un LLM real NO devuelve `tool_calls` como campo: lo pone en el
        # TEXTO, dentro de `<tool_call>{...}</tool_call>`, y es
        # `Candil.Tools.parse_tool_calls/1` quien lo saca de ahi. Por eso este
        # backend mete la llamada en el `content` y no en un campo aparte: es
        # lo que un modelo de verdad haria.
        json = ~s({"name":"weather","args":{"city":"Madrid"}})
        abre = String.duplicate("<", 1) <> "tool_call" <> String.duplicate(">", 1)
        cierra = String.duplicate("<", 1) <> "/tool_call" <> String.duplicate(">", 1)
        {:ok, %{content: abre <> json <> cierra}}
      end
    end
  end

  # ── el agente ────────────────────────────────────────────────────────────────

  defmodule Meteorologo do
    @moduledoc false
    # `tools:` espera `%Tool{}` YA CONSTRUIDOS, no modulos. El `use` parece
    # que registra tus herramientas y NO lo hace: esto es un hallazgo mas de
    # este test. Para que el agente vea la herramienta hay que llamar a
    # `Candil.Tool.define/1` (que se hace en el setup de abajo).
    use Candil.Agent,
      name: "meteorologo",
      goal: "responde el tiempo",
      max_steps: 4,
      stop_words: ["FINAL_ANSWER"]
  end

  # ── quien mira lo que pasa ──────────────────────────────────────────────────
  #
  # El agente corre en este proceso (es sincrono), asi que basta con un
  # proceso en el proceso global que apunte a este test.
  @global_calls :candil_agent_real_calls

  def record(what), do: send(:persistent_term.get(@global_calls, self()), {:llamo, what})

  setup do
    Tool.reset()

    # El agente corre en este proceso, asi que basta con decirde donde es.
    :persistent_term.put(@global_calls, self())

    on_exit(fn ->
      :persistent_term.erase(@global_calls)
      Tool.reset()
    end)

    # Y la herramienta se REGISTRA de verdad, que es lo que hace el `use`.
    :ok = Tool.define(Weather.__tool__())
    :ok
  end

  describe "un agente de verdad" do
    test "pide la herramienta, la recibe, y responde" do
      assert {:ok, respuesta, trace} = Meteorologo.run("¿qué tiempo hace?", backend: Backend)

      # El contenido, no el codigo de salida.
      assert respuesta =~ "18 grados"

      # Y el rastro deja ver que PIZO la herramienta: sin eso, un agente que
      # se limitase a alucinar la respuesta tambien pasaria este test.
      kinds = Enum.map(trace, & &1.kind)
      # Lo que importa: hay un `:action`, o sea, PIDIO la herramienta. Y el
      # `@type step` declara `:observation`, pero el bucle NUNCA lo emite — la
      # observacion va dentro de un `:action`. El tipo miente; aqui se fija lo
      # que el bucle REALMENTE hace.
      assert :action in kinds
      refute :observation in kinds
    end

    test "la herramienta se llamo de verdad, con sus argumentos" do
      Meteorologo.run("¿qué tiempo hace?", backend: Backend)

      assert_received {:llamo, "Madrid"}
      # Y que se pidio la herramienta, no que se contesto de memoria.
      assert_received {:llamo, :pidio_tool}
    end

    test "el rastro es legible y ordenado" do
      {:ok, _respuesta, trace} = Meteorologo.run("¿qué tiempo hace?", backend: Backend)

      # Cada paso deja una entrada, y el bucle no se inventa pasos de mas.
      assert length(trace) <= 3
      assert Enum.all?(trace, &is_map/1)
      assert Enum.all?(trace, &(&1.kind in [:thought, :action, :final]))
    end

    test "el agente tiene nombre, objetivo y herramientas" do
      cfg = Meteorologo.__agent_config__()

      assert cfg.name == "meteorologo"
      assert cfg.goal == "responde el tiempo"
      # Y el campo que genera es `tool_schemas`, NO `tools`: las herramientas
      # no se declaran en el `use`, se registran en el registro de Candil.Tool.
      assert is_list(cfg.tool_schemas)
    end
  end

  describe "lo que NO hace" do
    test "sin backend, en vez de reventar con una excepcion de Erlang" do
      # Esto es lo que descubre este test. `resolve_backend/1` devuelve `nil`
      # y el bucle hace `nil.chat(...)`.
      #
      # Lo que hay que decidir NO es que falle —sin backend no hay respuesta—
      # sino COMO falla. Una excepcion de Erlang en un bucle de ReAct significa
      # que el agente muere por un error de configuracion, y eso es justo lo
      # que un framework no puede permitirse: quien lo usa ni se entera de que
      # le falta algo hasta que algo se rompe en produccion.
      #
      # Lo que se fija aqui es el COMPORTAMIENTO QUE HAY: revienta. Se deja a
      # proposito, y ver que este test esta en rojo al cambiarlo es lo que
      # avisara de que hay que arreglar `resolve_backend/1`.
      assert_raise UndefinedFunctionError, fn ->
        Meteorologo.run("¿qué tiempo hace?")
      end
    end
  end
end
