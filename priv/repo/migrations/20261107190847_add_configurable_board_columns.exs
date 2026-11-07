defmodule Devloom.Repo.Migrations.AddConfigurableBoardColumns do
  use Ecto.Migration

  def up do
    create table(:board_columns) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :title, :string, null: false
      add :description, :string, null: false, default: ""
      add :color, :string, null: false, default: "blue"
      add :completed, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_columns, [:board_id, :key])

    create unique_index(:board_columns, [:board_id, "lower(title)"],
             name: :board_columns_board_title_index
           )

    create index(:board_columns, [:board_id, :position, :id])

    create constraint(:board_columns, :valid_column_color,
             check: "color IN ('neutral', 'blue', 'amber', 'purple', 'green', 'rose')"
           )

    create constraint(:board_columns, :valid_column_position, check: "position >= 0")

    execute """
    INSERT INTO board_columns
      (board_id, key, title, description, color, completed, position, lock_version, inserted_at, updated_at)
    SELECT boards.id, defaults.key, defaults.title, defaults.description, defaults.color,
      defaults.completed, defaults.position, 1, timezone('UTC', now()), timezone('UTC', now())
    FROM boards
    CROSS JOIN (VALUES
      ('backlog', 'Backlog', 'Ideas taking shape', 'neutral', false, 0),
      ('todo', 'To do', 'Ready to get started', 'blue', false, 1),
      ('in_progress', 'In progress', 'Good things in motion', 'amber', false, 2),
      ('in_review', 'In review', 'A fresh pair of eyes', 'purple', false, 3),
      ('done', 'Done', 'Built, checked, shipped', 'green', true, 4)
    ) AS defaults(key, title, description, color, completed, position)
    """

    drop constraint(:work_items, :valid_status)

    alter table(:work_items) do
      modify :status, :string, default: nil, null: false
    end

    execute """
    ALTER TABLE work_items ADD CONSTRAINT work_items_column_fkey
    FOREIGN KEY (board_id, status) REFERENCES board_columns (board_id, key)
    ON DELETE RESTRICT
    """
  end

  def down do
    execute "ALTER TABLE work_items DROP CONSTRAINT work_items_column_fkey"

    # Keep every card if rolling back a custom workflow to the original five states.
    execute """
    UPDATE work_items SET status = 'backlog', lock_version = lock_version + 1,
      updated_at = timezone('UTC', now())
    WHERE status NOT IN ('backlog', 'todo', 'in_progress', 'in_review', 'done')
    """

    alter table(:work_items) do
      modify :status, :string, default: "backlog", null: false
    end

    create constraint(:work_items, :valid_status,
             check: "status IN ('backlog', 'todo', 'in_progress', 'in_review', 'done')"
           )

    drop table(:board_columns)
  end
end
