System.put_env("APP_MODE", "testing")
{:ok, _} = Application.ensure_all_started(:recipes)

ExUnit.start()
