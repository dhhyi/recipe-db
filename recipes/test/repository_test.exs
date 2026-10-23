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
    assert created["createdAt"] == created["updatedAt"]
    assert {:ok, datetime, 0} = DateTime.from_iso8601(created["createdAt"])
    assert elem(datetime.microsecond, 1) == 6

    assert {:ok, patched} =
             Repository.patch(
               created["id"],
               %{"metadata" => %{"season" => "autumn"}},
               repository
             )

    assert patched["metadata"] == %{"source" => "family", "season" => "autumn"}
    assert patched["createdAt"] == created["createdAt"]
    assert patched["updatedAt"] == created["updatedAt"]
    assert {:ok, [^patched]} = Repository.all(repository)
    assert :ok = Repository.delete(created["id"], repository)
    assert :not_found = Repository.get(created["id"], repository)
    assert :not_found = Repository.delete(created["id"], repository)
  end

  test "advances updatedAt only when effective core values change", %{repository: repository} do
    assert {:ok, created} =
             Repository.create(
               %{
                 "name" => "Rice Pudding",
                 "method" => "Cook",
                 "ingredients" => [%{"name" => "Rice"}, %{"name" => "Milk"}]
               },
               repository
             )

    Process.sleep(2)

    assert {:ok, unchanged} =
             Repository.patch(
               created["id"],
               %{
                 "name" => "Rice Pudding",
                 "metadata" => %{"source" => "family"},
                 "method" => "Cook"
               },
               repository
             )

    assert unchanged["updatedAt"] == created["updatedAt"]

    Process.sleep(2)

    assert {:ok, changed} =
             Repository.patch(
               created["id"],
               %{"ingredients" => [%{"name" => "Milk"}, %{"name" => "Rice"}]},
               repository
             )

    assert changed["createdAt"] == created["createdAt"]
    assert {:ok, updated_at, 0} = DateTime.from_iso8601(changed["updatedAt"])
    assert {:ok, created_at, 0} = DateTime.from_iso8601(created["updatedAt"])
    assert DateTime.compare(updated_at, created_at) == :gt

    Process.sleep(2)

    assert {:ok, ingredient_changed} =
             Repository.patch(
               created["id"],
               %{"ingredients" => [%{"name" => "Milk", "optional" => true}, %{"name" => "Rice"}]},
               repository
             )

    assert ingredient_changed["updatedAt"] != changed["updatedAt"]

    Process.sleep(2)

    assert {:ok, method_cleared} =
             Repository.patch(created["id"], %{"method" => nil}, repository)

    assert method_cleared["createdAt"] == created["createdAt"]
    assert method_cleared["updatedAt"] != ingredient_changed["updatedAt"]
    refute Map.has_key?(method_cleared, "method")
  end

  test "rejects direct attempts to write server-owned timestamps", %{repository: repository} do
    for field <- ["createdAt", "updatedAt"] do
      assert {:error, :reserved_field, _, ^field} =
               Repository.create(%{"name" => "Rice Pudding", field => nil}, repository)
    end

    assert {:ok, created} = Repository.create(%{"name" => "Rice Pudding"}, repository)

    for field <- ["createdAt", "updatedAt"] do
      assert {:error, :reserved_field, _, ^field} =
               Repository.patch(created["id"], %{field => nil}, repository)
    end

    assert {:ok, stored} = Repository.get(created["id"], repository)
    assert stored == created
  end

  test "persists timestamps across repository restarts" do
    database =
      Path.join(System.tmp_dir!(), "recipes-#{System.unique_integer([:positive])}.sqlite3")

    name = String.to_atom("repository_#{System.unique_integer([:positive])}")
    {:ok, first_pid} = Repository.start_link(database: database, name: name)
    assert {:ok, created} = Repository.create(%{"name" => "Rice Pudding"}, name)
    GenServer.stop(first_pid)

    {:ok, second_pid} = Repository.start_link(database: database, name: name)
    assert {:ok, fetched} = Repository.get(created["id"], name)
    assert fetched == created

    GenServer.stop(second_pid)
    File.rm(database)
  end

  test "rolls back a patch that removes the name", %{repository: repository} do
    assert {:ok, created} = Repository.create(%{"name" => "Rice Pudding"}, repository)

    assert {:error, :required_field, _, "name"} =
             Repository.patch(created["id"], %{"name" => nil}, repository)

    assert {:ok, stored} = Repository.get(created["id"], repository)
    assert stored == created
  end
end
