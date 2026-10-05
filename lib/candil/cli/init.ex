defmodule Candil.CLI.Init do
  @moduledoc """
  `candil init` — escribe una `candil.toml` plantilla.

  Existe porque el camino natural de quien acaba de instalar Candil es
  `candil models list`, y sin configuracion eso responde `no models configured.
  Check candil.toml` — que no dice **donde** esta ese fichero, ni que no
  existe, ni como se arregla. Un mensaje que dice que algo falta sin decir
  como crearlo es casi peor que no tener el comando.

  ## No pisa nada

  Si ya hay configuracion, `init` no la toca y lo dice. Con `--force` la
  pisa, y con `--path` escribe en otro sitio. Sin `--force` nunca se pierde un
  fichero que alguien escribio a mano, que es el unico dato que no se puede
  recuperar.

  ## Por que el texto va tal cual y no pasa por `Config.File.save/2`

  Porque la plantilla esta **comentada**. `save/2` serializa un mapa y de ahi
  no sale ni un `#`: escribir la plantilla con el serializador daria un
  `candil.toml` valido, vacio y sin una sola palabra de como se usa. Se
  escribe el texto directamente, y un test lo parsea para que siga siendo
  valido.
  """

  alias Alaja.Output
  alias Alaja.Printer, as: Say
  alias Apero.File, as: AperoFile
  alias Candil.Config.File, as: ConfigFile
  alias Candil.Config.Template

  @doc """
  Returns the escript exit status.
  """
  @spec run(map() | keyword()) :: :ok | :error
  def run(opts \\ []) do
    path = get(opts, :path) || ConfigFile.default_path()
    force? = get(opts, :force) == true

    if File.exists?(path) and not force? do
      Output.write_error("ya hay configuracion en #{path}")
      Say.print("No se toca. Para rehacerla desde la plantilla:")
      Say.print("  candil init --force")
      Say.print("Para escribirla en otro sitio, sin tocar esta:")
      Say.print("  candil init --path /tmp/prueba.toml")
      :ok
    else
      write(path)
    end
  end

  defp write(path) do
    case AperoFile.write(path, Template.render()) do
      :ok ->
        Say.print_message(:success, "escrita #{path}")
        Say.print("")
        Say.print("Todo esta comentado, asi que el fichero es valido y no hace")
        Say.print("nada todavia. Para registrar un modelo:")
        Say.print("  1. edita el fichero y descomenta un [model.<alias>] con su [.source]")
        Say.print("  2. candil models pull <alias>")
        Say.print("")
        Say.print("")
        Say.print("El resto de comandos leen siempre #{ConfigFile.default_path()},")
        Say.print("que es donde se guarda por defecto. --path solo decide donde")
        Say.print("escribe ESTE fichero, no mueve la configuracion:")
        Say.print("  CANDIL_CONFIG=#{path} candil models list")
        :ok

      {:error, reason} ->
        Output.write_error("no se pudo escribir #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get(_, _), do: nil
end
