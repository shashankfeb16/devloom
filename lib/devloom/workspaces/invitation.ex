defmodule Devloom.Workspaces.Invitation do
  @moduledoc "An expiring, single-use invitation whose secret is stored only as a hash."
  use Ecto.Schema
  import Ecto.Changeset

  schema "workspace_invitations" do
    field :email, :string
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :workspace, Devloom.Workspaces.Workspace
    belongs_to :inviter, Devloom.Accounts.User
    belongs_to :accepted_by, Devloom.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email])
    |> update_change(:email, &(String.trim(&1) |> String.downcase()))
    |> validate_required([:email])
    |> validate_length(:email, max: 160)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "enter a valid email address"
    )
  end
end
