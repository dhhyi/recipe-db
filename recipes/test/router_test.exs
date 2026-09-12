defmodule Recipes.RouterTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Recipes.{Repository, Router}

  @options Router.init([])

  setup do
    previous_testing = System.get_env("TESTING")
    System.put_env("TESTING", "true")
    :ok = Repository.clear()

    on_exit(fn ->
      if previous_testing do
        System.put_env("TESTING", previous_testing)
      else
        System.delete_env("TESTING")
      end
    end)
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
             "code" => "invalid-field",
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
