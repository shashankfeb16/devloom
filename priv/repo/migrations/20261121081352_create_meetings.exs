defmodule Devloom.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  def change do
    create table(:meetings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, on_delete: :nilify_all)
      add :host_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:meetings, [:workspace_id])
  end
end
