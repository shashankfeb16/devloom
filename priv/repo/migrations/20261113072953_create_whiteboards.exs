defmodule Devloom.Repo.Migrations.CreateWhiteboards do
  use Ecto.Migration

  def change do
    create table(:whiteboards) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false, default: "Team whiteboard"
      add :scene, :map, null: false, default: %{"elements" => []}
      add :revision, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:whiteboards, [:workspace_id])
    create constraint(:whiteboards, :whiteboards_positive_revision, check: "revision > 0")
  end
end
