defmodule Devloom.Repo.Migrations.AllowWorkspaceAdminRole do
  use Ecto.Migration

  def up do
    drop constraint(:workspace_memberships, :valid_workspace_role)

    create constraint(:workspace_memberships, :valid_workspace_role,
             check: "role IN ('owner', 'admin', 'member')"
           )
  end

  def down do
    drop constraint(:workspace_memberships, :valid_workspace_role)
    execute "UPDATE workspace_memberships SET role = 'member' WHERE role = 'admin'"

    create constraint(:workspace_memberships, :valid_workspace_role,
             check: "role IN ('owner', 'member')"
           )
  end
end
