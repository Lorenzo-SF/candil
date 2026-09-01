ExUnit.start()

Mox.defmock(Candil.HTTPAdapterMock, for: Apero.Http.Adapter)

# Use the mock adapter for ALL tests by default (deterministic, no real
# network). Tests that need specific behavior set expectations or stubs;
# the "unreachable host" tests stub a connection error.
Application.put_env(:apero, :http_adapter, Candil.HTTPAdapterMock)

# Ensure the Registry is started for tests that need it
case Registry.start_link(keys: :unique, name: Candil.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end
