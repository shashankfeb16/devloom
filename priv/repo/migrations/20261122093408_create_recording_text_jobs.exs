defmodule Devloom.Repo.Migrations.CreateRecordingTextJobs do
  use Ecto.Migration

  def change do
    create table(:recording_text_jobs) do
      add :recording_id, references(:meeting_recordings, type: :uuid, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :status, :string, null: false
      add :run_id, :uuid
      add :result, :map
      add :error, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:recording_text_jobs, [:recording_id, :kind])

    create index(:recording_text_jobs, [:status, :updated_at],
             where: "status IN ('queued', 'running')"
           )
  end
end
