defmodule Recipes.Problem do
  @moduledoc """
  Sends API errors as RFC 9457 Problem Details responses.
  """

  import Plug.Conn

  @spec send(Plug.Conn.t(), pos_integer(), String.t(), String.t(), String.t(), String.t() | nil) ::
          Plug.Conn.t()
  def send(conn, status, title, detail, code, field \\ nil) do
    body = %{
      "type" => "about:blank",
      "title" => title,
      "status" => status,
      "detail" => detail,
      "code" => code
    }

    body = if field, do: Map.put(body, "field", field), else: body

    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, Jason.encode!(body))
  end
end
