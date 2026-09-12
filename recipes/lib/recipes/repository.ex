defmodule Recipes.Repository do
  @moduledoc """
  Stores recipe documents in SQLite through a serialized GenServer interface.
  """

  use GenServer

  alias Recipes.Recipe

  @type result :: {:ok, map()} | :not_found | {:error, term()}

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def all(server \\ __MODULE__), do: GenServer.call(server, :all)
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)
  def create(document, server \\ __MODULE__), do: GenServer.call(server, {:create, document})
  def delete(id, server \\ __MODULE__), do: GenServer.call(server, {:delete, id})
  def get(id, server \\ __MODULE__), do: GenServer.call(server, {:get, id})
  def patch(id, patch, server \\ __MODULE__), do: GenServer.call(server, {:patch, id, patch})

  @impl true
  def init(options) do
    database = Keyword.get_lazy(options, :database, &database_path/0)
    database |> Path.dirname() |> File.mkdir_p!()

    with {:ok, connection} <-
           Exqlite.start_link(
             database: database,
             busy_timeout: 5_000,
             default_transaction_mode: :immediate
           ),
         {:ok, _result} <-
           Exqlite.query(
             connection,
             "CREATE TABLE IF NOT EXISTS recipes (id TEXT PRIMARY KEY, document TEXT NOT NULL)"
           ) do
      {:ok, connection}
    end
  end

  @impl true
  def handle_call(:all, _from, connection) do
    reply =
      case Exqlite.query(connection, "SELECT id, document FROM recipes ORDER BY rowid") do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode_row/1)}
        {:error, error} -> {:error, error}
      end

    {:reply, reply, connection}
  end

  def handle_call(:clear, _from, connection) do
    reply = query_without_rows(connection, "DELETE FROM recipes")
    {:reply, reply, connection}
  end

  def handle_call({:create, document}, _from, connection) do
    id = Recipe.new_id()

    reply =
      with {:ok, encoded} <- Jason.encode(document),
           {:ok, _result} <-
             Exqlite.query(connection, "INSERT INTO recipes (id, document) VALUES (?, ?)", [
               id,
               encoded
             ]) do
        {:ok, Map.put(document, "id", id)}
      end

    {:reply, reply, connection}
  end

  def handle_call({:delete, id}, _from, connection) do
    reply =
      case get_recipe(connection, id) do
        {:ok, _recipe} -> query_without_rows(connection, "DELETE FROM recipes WHERE id = ?", [id])
        :not_found -> :not_found
        {:error, error} -> {:error, error}
      end

    {:reply, reply, connection}
  end

  def handle_call({:get, id}, _from, connection) do
    {:reply, get_recipe(connection, id), connection}
  end

  def handle_call({:patch, id, patch}, _from, connection) do
    reply =
      Exqlite.transaction(connection, fn transaction ->
        with {:ok, current} <- get_recipe(transaction, id),
             document = current |> Map.delete("id") |> Recipe.merge_patch(patch),
             :ok <- Recipe.validate(document),
             {:ok, encoded} <- Jason.encode(document),
             {:ok, _result} <-
               Exqlite.query(transaction, "UPDATE recipes SET document = ? WHERE id = ?", [
                 encoded,
                 id
               ]) do
          {:ok, Map.put(document, "id", id)}
        else
          :not_found ->
            Exqlite.rollback(transaction, :not_found)

          {:error, reason} ->
            Exqlite.rollback(transaction, reason)

          {:error, code, detail, field} ->
            Exqlite.rollback(transaction, {:validation, code, detail, field})
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, :not_found} -> :not_found
        {:error, {:validation, code, detail, field}} -> {:error, code, detail, field}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, connection}
  end

  defp database_path do
    System.get_env("DATA_LOCATION", "db")
    |> Path.join("recipes.sqlite3")
  end

  defp decode_row([id, document]) do
    document
    |> Jason.decode!()
    |> Map.put("id", id)
  end

  defp get_recipe(connection, id) do
    case Exqlite.query(connection, "SELECT id, document FROM recipes WHERE id = ?", [id]) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> :not_found
      {:error, error} -> {:error, error}
    end
  end

  defp query_without_rows(connection, statement, parameters \\ []) do
    case Exqlite.query(connection, statement, parameters) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
