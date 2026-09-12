defmodule Recipes.Router do
  use Plug.Router

  require Logger

  alias Recipes.{Problem, Recipe, Repository}

  plug(:normalize_trailing_slash)
  plug(:record_request)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 204, "")
  end

  get "/recipes" do
    case Repository.all() do
      {:ok, recipes} -> json(conn, 200, recipes)
      {:error, error} -> database_error(conn, error)
    end
  end

  post "/recipes" do
    with {:ok, document, conn} <- decode_body(conn, "application/json"),
         :ok <- Recipe.validate(document),
         {:ok, recipe} <- Repository.create(document) do
      json(conn, 201, recipe)
    else
      {:error, conn, status, title, detail, code} ->
        Problem.send(conn, status, title, detail, code)

      {:error, code, detail, field} ->
        Problem.send(conn, 422, "Unprocessable Content", detail, code_string(code), field)

      {:error, error} ->
        database_error(conn, error)
    end
  end

  delete "/recipes" do
    if System.get_env("TESTING") == "true" do
      case Repository.clear() do
        :ok -> send_resp(conn, 204, "")
        {:error, error} -> database_error(conn, error)
      end
    else
      Problem.send(conn, 404, "Not Found", "Route not found", "not-found")
    end
  end

  get "/recipes/:id" do
    case Repository.get(id) do
      {:ok, recipe} -> json(conn, 200, recipe)
      :not_found -> recipe_not_found(conn)
      {:error, error} -> database_error(conn, error)
    end
  end

  patch "/recipes/:id" do
    with {:ok, patch, conn} <- decode_body(conn, "application/merge-patch+json"),
         :ok <- Recipe.validate_patch(patch),
         {:ok, recipe} <- Repository.patch(id, patch) do
      json(conn, 200, recipe)
    else
      {:error, conn, status, title, detail, code} ->
        Problem.send(conn, status, title, detail, code)

      {:error, code, detail, field} ->
        Problem.send(conn, 422, "Unprocessable Content", detail, code_string(code), field)

      :not_found ->
        recipe_not_found(conn)

      {:error, error} ->
        database_error(conn, error)
    end
  end

  delete "/recipes/:id" do
    case Repository.delete(id) do
      :ok -> send_resp(conn, 204, "")
      :not_found -> recipe_not_found(conn)
      {:error, error} -> database_error(conn, error)
    end
  end

  match "/recipes" do
    conn
    |> put_resp_header("allow", collection_methods())
    |> Problem.send(405, "Method Not Allowed", "Method not allowed", "method-not-allowed")
  end

  match "/recipes/:id" do
    conn
    |> put_resp_header("allow", "GET, PATCH, DELETE")
    |> Problem.send(405, "Method Not Allowed", "Method not allowed", "method-not-allowed")
  end

  match _ do
    Problem.send(conn, 404, "Not Found", "Route not found", "not-found")
  end

  defp normalize_trailing_slash(%Plug.Conn{path_info: path_info} = conn, _options) do
    case path_info do
      [_ | _] ->
        %{
          conn
          | path_info: Enum.drop_while(Enum.reverse(path_info), &(&1 == "")) |> Enum.reverse()
        }

      [] ->
        conn
    end
  end

  defp record_request(conn, _options) do
    started_at = System.monotonic_time()
    verbose = System.get_env("VERBOSE") == "true"

    if verbose, do: Logger.info("#{conn.method} #{conn.request_path}")

    register_before_send(conn, fn response ->
      if verbose or response.status >= 400 do
        duration = System.monotonic_time() - started_at
        milliseconds = System.convert_time_unit(duration, :native, :microsecond) / 1_000
        Logger.info("#{conn.method} #{conn.request_path} #{response.status} #{milliseconds}ms")
      end

      response
    end)
  end

  defp decode_body(conn, expected_content_type) do
    case get_req_header(conn, "content-type") do
      [content_type | _] ->
        if media_type(content_type) == expected_content_type do
          parse_body(conn)
        else
          {:error, conn, 415, "Unsupported Media Type", "Expected #{expected_content_type}",
           "unsupported-media-type"}
        end

      [] ->
        {:error, conn, 415, "Unsupported Media Type", "Expected #{expected_content_type}",
         "unsupported-media-type"}
    end
  end

  defp parse_body(conn) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, document} <- Jason.decode(body),
         true <- is_map(document) do
      {:ok, document, conn}
    else
      false ->
        {:error, conn, 400, "Bad Request", "Expected a JSON object", "invalid-json-object"}

      {:error, %Jason.DecodeError{}} ->
        {:error, conn, 400, "Bad Request", "Invalid JSON", "invalid-json"}

      {:more, _body, conn} ->
        {:error, conn, 413, "Content Too Large", "Request body is too large", "content-too-large"}
    end
  end

  defp media_type(content_type),
    do: content_type |> String.split(";", parts: 2) |> hd() |> String.trim()

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp recipe_not_found(conn) do
    Problem.send(conn, 404, "Not Found", "Recipe not found", "recipe-not-found")
  end

  defp database_error(conn, error) do
    Logger.error("Database error: #{inspect(error)}")

    Problem.send(
      conn,
      500,
      "Internal Server Error",
      "Database operation failed",
      "database-error"
    )
  end

  defp collection_methods do
    if System.get_env("TESTING") == "true", do: "GET, POST, DELETE", else: "GET, POST"
  end

  defp code_string(code), do: code |> Atom.to_string() |> String.replace("_", "-")
end
