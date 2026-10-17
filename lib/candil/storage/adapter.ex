defmodule Candil.Storage.Adapter do
  @moduledoc """
  El contrato de un adaptador de almacenamiento.

  Un adaptador es un módulo que sabe guardar y leer valores por clave. El
  almacenamiento no sabe qué guarda; solo sabe que hay una clave y un valor.
  `Candil.Storage.Store` elige el adaptador y delega.

  ## Por qué un behaviour y no una función

  Porque el día que alguien quiera guardar en Postgres en vez de en ETS, no
  tiene que tocar `Candil.Storage.Store`. Implementa este behaviour y se
  registra. Eso es lo que hace que esto sea un framework y no un programa con
  una tabla.
  """

  @doc "Inicializa el adaptador. Devuelve `{:ok, state}`."
  @callback init(keyword()) :: {:ok, term()}

  @doc "Lee el valor de `key`. `{:error, :not_found}` si no está."
  @callback get(state :: term(), key :: term()) :: {:ok, term()} | {:error, :not_found}

  @doc "Guarda `value` bajo `key`. Devuelve el estado nuevo."
  @callback put(state :: term(), key :: term(), value :: term()) :: {:ok, term()}

  @doc "Borra `key`. Devuelve el estado nuevo."
  @callback delete(state :: term(), key :: term()) :: {:ok, term()}

  @doc "Lista todos los valores."
  @callback list(state :: term()) :: {:ok, [term()], term()}

  @doc "Cuenta los valores."
  @callback count(state :: term()) :: {:ok, non_neg_integer(), term()}
end
