defmodule Recipes.RepositoryTest do
  use ExUnit.Case

  alias Recipes.Repository

  setup do
    database =
      Path.join(System.tmp_dir!(), "recipes-#{System.unique_integer([:positive])}.sqlite3")

    name = String.to_atom("repository_#{System.unique_integer([:positive])}")
    start_supervised!({Repository, database: database, name: name})
    on_exit(fn -> File.rm(database) end)
    %{repository: name}
  end

  test "stores, patches, lists, and deletes recipes", %{repository: repository} do
    assert {:ok, created} =
             Repository.create(
               %{
                 "name" => "Rice Pudding",
                 "metadata" => %{"source" => "family", "season" => "winter"}
               },
               repository
             )

    assert {:ok, fetched} = Repository.get(created["id"], repository)
    assert fetched == created

    assert {:ok, patched} =
             Repository.patch(
               created["id"],
               %{"metadata" => %{"season" => "autumn"}},
               repository
             )

    assert patched["metadata"] == %{"source" => "family", "season" => "autumn"}
    assert {:ok, [^patched]} = Repository.all(repository)
    assert :ok = Repository.delete(created["id"], repository)
    assert :not_found = Repository.get(created["id"], repository)
    assert :not_found = Repository.delete(created["id"], repository)
  end

  test "rolls back a patch that removes the name", %{repository: repository} do
    assert {:ok, created} = Repository.create(%{"name" => "Rice Pudding"}, repository)

    assert {:error, :invalid_field, _, "name"} =
             Repository.patch(created["id"], %{"name" => nil}, repository)

    assert {:ok, stored} = Repository.get(created["id"], repository)
    assert stored["name"] == "Rice Pudding"
  end
end
