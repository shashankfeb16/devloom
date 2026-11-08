defmodule Devloom.Repo.Migrations.AddWorkspacesMembershipsAndInvitations do
  use Ecto.Migration

  def up do
    create table(:workspaces) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :legacy, :boolean, null: false, default: false
      add :legacy_claimed, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])
    create unique_index(:workspaces, [:legacy], where: "legacy = true")

    create table(:workspace_memberships) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
    create index(:workspace_memberships, [:user_id])

    create constraint(:workspace_memberships, :valid_workspace_role,
             check: "role IN ('owner', 'member')"
           )

    create table(:workspace_invitations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :inviter_id, references(:users, on_delete: :delete_all), null: false
      add :accepted_by_id, references(:users, on_delete: :nilify_all)
      add :email, :string, size: 160, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_invitations, [:token_hash])
    create index(:workspace_invitations, [:workspace_id, :email])

    execute """
    INSERT INTO workspaces (name, slug, legacy, legacy_claimed, inserted_at, updated_at)
    VALUES ('Devloom', 'legacy-devloom', true, false, NOW(), NOW())
    """

    alter table(:boards) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
    end

    execute """
    UPDATE boards SET workspace_id = (SELECT id FROM workspaces WHERE legacy = true)
    """

    alter table(:boards) do
      modify :workspace_id, :bigint, null: false
    end

    create index(:boards, [:workspace_id])

    alter table(:chat_messages) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:chat_messages, [:user_id])
  end

  def down do
    alter table(:chat_messages) do
      remove :user_id
    end

    alter table(:boards) do
      remove :workspace_id
    end

    drop table(:workspace_invitations)
    drop table(:workspace_memberships)
    drop table(:workspaces)
  end
end
