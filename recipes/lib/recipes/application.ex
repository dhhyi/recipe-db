defmodule Recipes.Application do
  @moduledoc """
  Starts the recipe repository and HTTP server.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Recipes.Repository, []},
      {Bandit, plug: Recipes.Router, port: 5000, ip: {0, 0, 0, 0}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Recipes.Supervisor)
  end
end
