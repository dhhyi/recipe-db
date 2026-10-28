defmodule Recipes.RuntimeMode do
  @moduledoc false

  def from_env!, do: parse(System.get_env("MODE"))

  def parse(value) do
    case value do
      nil -> :production
      "production" -> :production
      "testing" -> :testing
      value -> raise ~s/Invalid MODE=#{inspect(value)}; expected "production" or "testing"/
    end
  end
end
