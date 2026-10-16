defmodule Candil.Agents.SupervisorTest do
  @moduledoc """
  El supervisor de agentes: arranca vacío, acepta hijos, los para, y levanta al
  que se cae.

  ## Por qué este test existe

  La F5.1 (`docs/04-modulos/05-agentes` §3.2) trae el supervisor antes que al
  primer agente, así que aquí el hijo no piensa: es un `GenServer` vacío que
  solo tiene lo que el supervisor exige — `child_spec/1` y `start_link/1`. Lo
  que se prueba es la puerta de entrada y la estrategia.
  """

  use ExUnit.Case, async: false

  alias Candil.Agents.Supervisor

  defmodule DummyAgent do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{name: opts[:name]}}
  end

  setup do
    start_supervised!(Supervisor)
    :ok
  end

  test "arranca vacío" do
    assert Supervisor.list_agents() == []
  end

  test "start_agent/2 arranca un hijo, y vuelve en la lista" do
    assert {:ok, pid} = Supervisor.start_agent(DummyAgent, name: "uno")

    assert [{:undefined, ^pid, :worker, [DummyAgent]}] = Supervisor.list_agents()
  end

  test "stop_agent/1 lo para; pararlo otra vez dice que no está" do
    {:ok, pid} = Supervisor.start_agent(DummyAgent, name: "dos")

    assert :ok = Supervisor.stop_agent(pid)
    assert Supervisor.list_agents() == []
    assert {:error, :not_found} = Supervisor.stop_agent(pid)
  end

  test "el que se cae vuelve: el reinicio vive aquí" do
    {:ok, primero} = Supervisor.start_agent(DummyAgent, name: "tres")

    Process.exit(primero, :kill)

    assert wait_until(fn ->
             Supervisor.list_agents()
             |> Enum.any?(fn {_, pid, _, _} -> is_pid(pid) and pid != primero end)
           end)
  end

  # El reinicio es del supervisor, no del test: cuando `Process.exit/2` vuelve,
  # el hijo todavía no está arriba. Se espera con tope; si no llega, el assert
  # de arriba falla, que es lo que tiene que hacer.
  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
