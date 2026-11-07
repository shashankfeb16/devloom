defmodule Devloom.Repo.Migrations.CreateKanbanBoardsAndWorkItems do
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boards, [:slug])

    create table(:work_items) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text, default: ""
      add :status, :string, null: false, default: "backlog"
      add :type, :string, null: false, default: "task"
      add :priority, :string, null: false, default: "medium"
      add :labels, {:array, :string}, null: false, default: []
      add :assignee, :string
      add :estimate, :integer
      add :position, :integer, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:work_items, [:board_id, :status, :position, :id])

    create constraint(:work_items, :valid_status,
             check: "status IN ('backlog', 'todo', 'in_progress', 'in_review', 'done')"
           )

    create constraint(:work_items, :valid_type, check: "type IN ('feature', 'task', 'bug')")

    create constraint(:work_items, :valid_priority,
             check: "priority IN ('low', 'medium', 'high', 'urgent')"
           )

    create constraint(:work_items, :valid_position, check: "position >= 0")
    create constraint(:work_items, :valid_estimate, check: "estimate BETWEEN 0 AND 100")
  end
end
