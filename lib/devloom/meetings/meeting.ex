defmodule Devloom.Meetings.Meeting do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "meetings" do
    belongs_to :workspace, Devloom.Workspaces.Workspace
    belongs_to :host, Devloom.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def room_name(%__MODULE__{id: id}), do: "devloom-" <> id
end
