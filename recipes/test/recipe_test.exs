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

  test "rejects client-supplied server-owned fields on create and patch" do
    for field <- ["createdAt", "updatedAt", "nameSortKey"] do
      assert {:error, :reserved_field, _, ^field} =
               Recipe.validate(%{"name" => "Rice Pudding", field => nil})

      assert {:error, :reserved_field, _, ^field} =
               Recipe.validate_patch(%{field => nil})
    end
  end

  test "detects changes to effective core values" do
    original = %{"name" => "Rice Pudding", "ingredients" => [%{"name" => "Rice"}]}

    refute Recipe.core_changed?(original, Map.put(original, "method", nil))
    refute Recipe.core_changed?(original, Map.put(original, "name", "Rice Pudding"))
    refute Recipe.core_changed?(original, Map.put(original, "nameSortKey", "rice pudding"))

    assert Recipe.core_changed?(
             original,
             Map.put(original, "ingredients", [%{"name" => "Milk"}, %{"name" => "Rice"}])
           )
  end

  test "derives normalized name sort keys without changing display names" do
    for {name, expected} <- [
          {" \tÄÖÜ Straße ẞ\n", "aou strasse ss"},
          {"A\u0308pfel O\u0308l U\u0308ber", "apfel ol uber"},
          {"  ÉCLAIR ΩМЛЕТ ", "éclair ωмлет"},
          {"  Tea  &  Cake! ", "tea  &  cake!"}
        ] do
      assert Recipe.name_sort_key(name) == expected

      assert Recipe.with_derived_fields(%{"name" => name}) == %{
               "name" => name,
               "nameSortKey" => expected
             }
    end
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
