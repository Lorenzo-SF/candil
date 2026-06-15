ExUnit.start()

# Ensure the Registry is started for tests that need it
case Registry.start_link(keys: :unique, name: Candil.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end
