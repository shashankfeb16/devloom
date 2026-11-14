defmodule Devloom.Release do
  @moduledoc """
  Database maintenance commands for the production release, without Mix.
  """

  @app :devloom

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
