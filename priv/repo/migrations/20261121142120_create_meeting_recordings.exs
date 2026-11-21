defmodule Devloom.Repo.Migrations.CreateMeetingRecordings do
  use Ecto.Migration

  def change do
    create table(:meeting_recordings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, on_delete: :nilify_all)
      add :started_by_id, references(:users, on_delete: :nilify_all)
      add :meeting_id, :uuid, null: false
      add :egress_id, :string
      add :status, :string, null: false
      add :duration_seconds, :integer
      add :size_bytes, :bigint
      timestamps(type: :utc_datetime)
    end

    create index(:meeting_recordings, [:workspace_id, :inserted_at])

    create unique_index(:meeting_recordings, [:meeting_id],
             where: "status IN ('starting', 'recording', 'processing')"
           )
  end
end
