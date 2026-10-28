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

  test "bulk delete is testing-only and preserves data when denied" do
    recipe = %{"name" => "Rice Pudding"}
    assert {:ok, created} = Repository.create(recipe)

    testing =
      :delete
      |> conn("/recipes/")
      |> Router.call(@options)

    assert testing.status == 204
    assert {:ok, []} = Repository.all()

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

  test "creates and patches a recipe using the required media types" do
    created =
      :post
      |> conn(
        "/recipes/",
        Jason.encode!(%{
          "name" => "Rice Pudding",
          "servings" => 4,
          "metadata" => %{"source" => "family", "season" => "winter"}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert created.status == 201
    assert ["application/json; charset=utf-8"] = get_resp_header(created, "content-type")
    recipe = Jason.decode!(created.resp_body)
    assert recipe["nameSortKey"] == "rice pudding"
    assert recipe["createdAt"] == recipe["updatedAt"]

    listed =
      :get
      |> conn("/recipes")
      |> Router.call(@options)

    assert listed.status == 200
    assert [listed_recipe] = Jason.decode!(listed.resp_body)
    assert listed_recipe == recipe

    fetched =
      :get
      |> conn("/recipes/#{recipe["id"]}")
      |> Router.call(@options)

    assert Jason.decode!(fetched.resp_body) == recipe

    patched =
      :patch
      |> conn(
        "/recipes/#{recipe["id"]}",
        Jason.encode!(%{
          "servings" => nil,
          "metadata" => %{"season" => "autumn"}
        })
      )
      |> put_req_header("content-type", "application/merge-patch+json")
      |> Router.call(@options)

    assert patched.status == 200
    body = Jason.decode!(patched.resp_body)
    refute Map.has_key?(body, "servings")
    assert body["metadata"] == %{"source" => "family", "season" => "autumn"}
    assert body["createdAt"] == recipe["createdAt"]
    assert body["updatedAt"] == recipe["updatedAt"]
    assert body["nameSortKey"] == "rice pudding"
  end

  test "rejects client-supplied server-owned fields including null values" do
    for field <- ["createdAt", "updatedAt", "nameSortKey"], value <- [nil, "client value"] do
      created =
        :post
        |> conn("/recipes", Jason.encode!(%{"name" => "Rice Pudding"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@options)

      recipe = Jason.decode!(created.resp_body)

      post_response =
        :post
        |> conn("/recipes", Jason.encode!(%{"name" => "Rice Pudding", field => value}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@options)

      assert post_response.status == 422

      assert %{"code" => "reserved-field", "field" => ^field} =
               Jason.decode!(post_response.resp_body)

      patch_response =
        :patch
        |> conn("/recipes/#{recipe["id"]}", Jason.encode!(%{field => value}))
        |> put_req_header("content-type", "application/merge-patch+json")
        |> Router.call(@options)

      assert patch_response.status == 422

      assert %{"code" => "reserved-field", "field" => ^field} =
               Jason.decode!(patch_response.resp_body)

      assert {:ok, ^recipe} = Repository.get(recipe["id"])
    end
  end

  test "returns problem details for invalid recipes" do
    response =
      :post
      |> conn("/recipes", Jason.encode!(%{"name" => ""}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert response.status == 422

    assert ["application/problem+json; charset=utf-8"] =
             get_resp_header(response, "content-type")

    assert %{
             "status" => 422,
             "detail" => "Missing field value for name",
             "code" => "required-field",
             "field" => "name"
           } = Jason.decode!(response.resp_body)
  end

  test "rejects unsupported media types" do
    response =
      :patch
      |> conn("/recipes/unknown", ~s({"name":"Updated"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert response.status == 415
    assert %{"code" => "unsupported-media-type"} = Jason.decode!(response.resp_body)
  end

  test "does not expose PUT" do
    response =
      :put
      |> conn("/recipes/unknown", ~s({"name":"Updated"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@options)

    assert response.status == 405
    assert ["GET, PATCH, DELETE"] = get_resp_header(response, "allow")
    assert %{"code" => "method-not-allowed"} = Jason.decode!(response.resp_body)
  end
end
