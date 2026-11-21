defmodule Recipes.StorageVersionTest do
  use ExUnit.Case

  alias Recipes.StorageVersion

  test "initializes fresh storage, publishes its marker, and refuses backup initialization" do
    root = Path.join(__DIR__, "storage-version-#{System.unique_integer([:positive])}")
    database = Path.join(root, "recipes.sqlite3")
    marker = Path.join(root, "storage-version")
    on_exit(fn -> File.rm_rf!(root) end)

    assert :fresh = StorageVersion.check!(database, "production")

    assert_raise RuntimeError, ~r/expected 1.*backup mode cannot initialize/, fn ->
      StorageVersion.check!(database, "backup")
    end

    assert_raise RuntimeError, ~r/backup mode cannot initialize/, fn ->
      StorageVersion.check!(database, :backup)
    end

    File.mkdir_p!(root)
    File.write!(database, "existing")

    assert_raise RuntimeError, ~r/marker missing; existing data found/, fn ->
      StorageVersion.check!(database, "testing")
    end

    assert_raise RuntimeError, ~r/marker missing; existing data found/, fn ->
      StorageVersion.check!(database, "testing")
    end

    assert File.read!(database) == "existing"
    File.rm!(database)
    assert :fresh = StorageVersion.check!(database, "testing")
    StorageVersion.publish!(database)
    assert File.read!(marker) == "1\n"
    assert :initialize = StorageVersion.check!(database, "production")

    assert_raise RuntimeError, ~r/backup mode cannot initialize/, fn ->
      StorageVersion.check!(database, "backup")
    end

    File.write!(database, "database")
    assert :ready = StorageVersion.check!(database, "production")

    assert_raise RuntimeError, ~r/cannot atomically publish marker/, fn ->
      StorageVersion.publish!(database)
    end

    assert File.read!(marker) == "1\n"
  end
end
