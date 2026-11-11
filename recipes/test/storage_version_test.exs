defmodule Recipes.StorageVersionTest do
  use ExUnit.Case

  alias Recipes.StorageVersion

  test "allows only fresh production and testing storage to initialize" do
    root = Path.join(__DIR__, "storage-version-#{System.unique_integer([:positive])}")
    database = Path.join(root, "recipes.sqlite3")
    marker = Path.join(root, "storage-version")
    on_exit(fn -> File.rm_rf!(root) end)

    assert :fresh = StorageVersion.check!(database, "production")

    assert_raise RuntimeError, ~r/expected 1.*backup mode cannot initialize/, fn ->
      StorageVersion.check!(database, "backup")
    end

    File.mkdir_p!(root)
    File.write!(Path.join(root, "unknown"), "untouched")

    assert_raise RuntimeError, ~r/marker missing; existing data found/, fn ->
      StorageVersion.check!(database, "testing")
    end

    assert File.read!(Path.join(root, "unknown")) == "untouched"
    File.rm!(Path.join(root, "unknown"))

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

    File.write!(marker, "2\n")

    assert_raise RuntimeError, ~r/expected 1, actual 2/, fn ->
      StorageVersion.check!(database, "testing")
    end

    assert File.read!(marker) == "2\n"
  end

  test "rejects malformed and unsafe markers without changing them" do
    root = Path.join(__DIR__, "storage-version-#{System.unique_integer([:positive])}")
    database = Path.join(root, "recipes.sqlite3")
    marker = Path.join(root, "storage-version")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)

    for contents <- ["", "0\n", "01\n", "1", "1\nextra"] do
      File.write!(marker, contents)

      assert_raise RuntimeError, ~r/invalid marker contents/, fn ->
        StorageVersion.check!(database, "production")
      end

      assert File.read!(marker) == contents
    end

    File.rm!(marker)
    File.mkdir!(marker)

    assert_raise RuntimeError, ~r/unsafe marker file type/, fn ->
      StorageVersion.check!(database, "testing")
    end
  end
end
