defmodule Recipes.RecipeTest do
  use ExUnit.Case, async: true

  alias Recipes.Recipe

  test "generates RFC 4122 version 4 UUIDs" do
    id = Recipe.new_id()

    assert String.length(id) == 36
    assert {:ok, %{version: 4}} = Uniq.UUID.info(id)
  end

  test "requires a nonblank string name" do
    assert :ok = Recipe.validate(%{"name" => "Rice Pudding"})
    assert {:error, :required_field, _, "name"} = Recipe.validate(%{"name" => "  "})
    assert {:error, :required_field, _, "name"} = Recipe.validate(%{"name" => 42})
  end

  test "rejects a reserved id" do
    assert {:error, :reserved_field, _, "id"} =
             Recipe.validate(%{"id" => "client-id", "name" => "Rice Pudding"})
  end

  test "applies recursive JSON merge patch semantics" do
    recipe = %{
      "name" => "Rice Pudding",
      "servings" => 4,
      "metadata" => %{"source" => "family", "season" => "winter"},
      "tags" => ["dessert", "rice"]
    }

    patch = %{
      "servings" => nil,
      "metadata" => %{"season" => "autumn"},
      "tags" => ["dessert"]
    }

    assert Recipe.merge_patch(recipe, patch) == %{
             "name" => "Rice Pudding",
             "metadata" => %{"source" => "family", "season" => "autumn"},
             "tags" => ["dessert"]
           }
  end
end
