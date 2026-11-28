defmodule Recipes.RecipeTest do
  use ExUnit.Case, async: true

  alias Recipes.Recipe

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
end
