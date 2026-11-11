defmodule Recipes.StorageVersionMissingDatabaseTest do
  use ExUnit.Case, async: true

  alias Recipes.StorageVersion

  test "a matching marker and leftover sidecar do not initialize a missing database in backup mode" do
    root =
      Path.join(
        System.tmp_dir!(),
        "recipes-storage-version-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    database = Path.join(root, "recipes.sqlite3")
    File.write!(Path.join(root, "storage-version"), "1\n")
    File.write!(database <> "-wal", "")

    assert_raise RuntimeError, ~r/database file is missing/, fn ->
      StorageVersion.check!(database, "backup")
    end

    refute File.exists?(database)
  end
end
