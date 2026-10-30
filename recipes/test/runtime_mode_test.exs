defmodule Recipes.RuntimeModeTest do
  use ExUnit.Case, async: true

  alias Recipes.RuntimeMode

  test "defaults to production and accepts explicit modes" do
    assert RuntimeMode.parse(nil) == :production
    assert RuntimeMode.parse("production") == :production
    assert RuntimeMode.parse("testing") == :testing
    assert RuntimeMode.parse("backup") == :backup
  end

  test "rejects empty and unsupported modes" do
    for mode <- ["", "Production", " production", "testing "] do
      assert_raise RuntimeError,
                   ~s(Invalid MODE="#{mode}"; expected "production", "testing" or "backup"),
                   fn ->
                     RuntimeMode.parse(mode)
                   end
    end
  end
end
