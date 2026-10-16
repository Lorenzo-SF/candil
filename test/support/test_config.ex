defmodule Candil.TestConfig do
  @moduledoc """
  A `candil.toml` of the test's own, and **the one the floor had** when it
  finishes.

  ## Por que existe

  `test_helper.exs` pone un suelo: la suite nunca lee el `~/.config/candil/
  candil.toml` de quien la ejecuta. Eso solo vale si cada test que **sube** un
  fichero de configuracion lo **baja** al salir, y seis de ellos no lo bajaban:
  hacian `System.delete_env("CANDIL_CONFIG")`, que con el suelo puesto no
  devuelve el suelo — lo **borra**. El resultado es que el primer test de la
  suite que toca la variable deja a los siguientes sin suelo, y a partir de ahi
  cada test lee el catalogo del developer otra vez.

  ## Medido, no supuesto

  El 2026-10-15, con `CANDIL_CONFIG` apuntando a un fichero que no existe:

    * `mix test --seed 0` da **2 fallos** y no 1, y ninguno de los dos es del
      fichero que borro la variable.
    * uno de ellos es **de verdad**: `GET /v1/models` contesta 500 con el cuerpo
      **vacio**, porque un alias del catalogo (`coder_lite`) no existe como
      atomo en la VM cuando lo pide un consumer. Ese fallo no se veia con el
      toml del developer, donde los atomos ya estaban creados.

  Un test que borra el suelo de los demas es el mismo disease que el
  `instances.json` en el `~/.candil` de otro: **un test que nadie corre dos
  veces**. Y se arregla en un sitio, no en seis.

  ## Como se usa

      setup do
        Candil.TestConfig.override!(Path.join(tmp, "candil.toml"))
        # ... escribir el fichero, o no: un path que no existe es «sin
        # configuracion», que es una configuracion valida y la mas comun.
        :ok
      end

  Se llama desde el proceso del test: `on_exit/1` de ExUnit solo funciona ahi.
  """

  @doc """
  Points `CANDIL_CONFIG` at `path` for this test only.

  `path` does not need to exist: `Candil.Config.File.load/0` treats a missing
  file as an empty configuration, and that is a legitimate thing for a test to
  ask for — it is the library case, with no file at all.
  """
  @spec override!(binary()) :: :ok
  def override!(path) when is_binary(path) do
    previous = System.get_env("CANDIL_CONFIG")
    System.put_env("CANDIL_CONFIG", path)
    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: System.delete_env("CANDIL_CONFIG")
  defp restore(previous), do: System.put_env("CANDIL_CONFIG", previous)
end
