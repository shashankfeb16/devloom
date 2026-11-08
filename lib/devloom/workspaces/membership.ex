defmodule Devloom.Workspaces.Membership do
  @moduledoc "A user's persisted role in one workspace."
  use Ecto.Schema

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: [:owner, :member], default: :member
    belongs_to :workspace, Devloom.Workspaces.Workspace
    belongs_to :user, Devloom.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
