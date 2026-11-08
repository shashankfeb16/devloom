defmodule Devloom.Workspaces.Workspace do
  @moduledoc "A team boundary for membership, boards, and conversations."
  use Ecto.Schema
  import Ecto.Changeset

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :legacy, :boolean, default: false
    field :legacy_claimed, :boolean, default: false
    field :role, Ecto.Enum, values: [:owner, :member], virtual: true
    field :member_count, :integer, virtual: true, default: 0
    has_many :memberships, Devloom.Workspaces.Membership
    has_many :boards, Devloom.Boards.Board
    timestamps(type: :utc_datetime)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint(:slug)
  end
end
