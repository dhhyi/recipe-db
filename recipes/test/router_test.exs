defmodule Recipes.RouterTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Recipes.{Repository, Router}

  @options Router.init([])

  setup do
    previous_mode = Application.fetch_env!(:recipes, :mode)
    Application.put_env(:recipes, :mode, :testing)
    :ok = Repository.clear()

    on_exit(fn ->
      Application.put_env(:recipes, :mode, previous_mode)
    end)
  end

  test "bulk delete is denied in production and preserves data" do
    recipe = %{"name" => "Rice Pudding"}
    assert {:ok, created} = Repository.create(recipe)

    Application.put_env(:recipes, :mode, :production)

    production =
      :delete
      |> conn("/recipes")
      |> Router.call(@options)

    assert production.status == 404
    assert %{"code" => "not-found"} = Jason.decode!(production.resp_body)
    assert {:ok, ^created} = Repository.get(created["id"])

    production_slash =
      :delete
      |> conn("/recipes/")
      |> Router.call(@options)

    assert production_slash.status == 404
    assert %{"code" => "not-found"} = Jason.decode!(production_slash.resp_body)
    assert {:ok, ^created} = Repository.get(created["id"])
  end

  test "collection HEAD is empty and testing-only without loading recipes" do
    response =
      :head
      |> conn("/recipes")
      |> Router.call(@options)

    assert response.status == 204
    assert response.resp_body == ""
    assert {:ok, []} = Repository.all()

    for mode <- [:production, :backup] do
      Application.put_env(:recipes, :mode, mode)

      denied =
        :head
        |> conn("/recipes")
        |> Router.call(@options)

      assert denied.status == 405
      assert ["GET, POST"] = get_resp_header(denied, "allow")
    end
  end

  test "backup mode exposes read-only maintenance inventory and rejects application writes" do
    assert {:ok, recipe} = Repository.create(%{"name" => "Rice Pudding"})
    Application.put_env(:recipes, :mode, :backup)

    status =
      :get
      |> conn("/maintenance/status")
      |> Router.call(@options)

    assert status.status == 200

    assert Jason.decode!(status.resp_body) == %{
             "version" => 1,
             "service" => "recipes",
             "mode" => "backup"
           }

    ids =
      :get
      |> conn("/maintenance/recipe-ids")
      |> Router.call(@options)

    assert Jason.decode!(ids.resp_body) == %{"recipeIds" => [recipe["id"]]}

    for request <- [
          conn(:post, "/recipes", Jason.encode!(%{"name" => "New Recipe"})),
          conn(:delete, "/recipes"),
          conn(:delete, "/recipes/"),
          conn(:patch, "/recipes/#{recipe["id"]}", Jason.encode!(%{"name" => "Changed"}))
        ] do
      response = Router.call(request, @options)
      assert response.status == 503
      assert %{"code" => "maintenance-mode"} = Jason.decode!(response.resp_body)
    end

    assert {:ok, ^recipe} = Repository.get(recipe["id"])

    Application.put_env(:recipes, :mode, :production)

    for path <- ["/maintenance/status", "/maintenance/recipe-ids"] do
      response = :get |> conn(path) |> Router.call(@options)
      assert response.status == 404
      assert %{"code" => "not-found"} = Jason.decode!(response.resp_body)
    end
  end
end
