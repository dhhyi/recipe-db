System.put_env("RECIPES_RUNTIME_MODE", "testing")
{:ok, _} = Application.ensure_all_started(:recipes)

ExUnit.start()
