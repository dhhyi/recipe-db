System.put_env("MODE", "testing")
{:ok, _} = Application.ensure_all_started(:recipes)

ExUnit.start()
