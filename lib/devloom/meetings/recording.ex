defmodule Devloom.Meetings.Recording do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "meeting_recordings" do
    belongs_to :workspace, Devloom.Workspaces.Workspace
    belongs_to :started_by, Devloom.Accounts.User
    # This ID survives the active meeting row being removed.
    field :meeting_id, Ecto.UUID
    field :egress_id, :string
    field :status, Ecto.Enum, values: [:starting, :recording, :processing, :ready, :failed]
    field :duration_seconds, :integer
    field :size_bytes, :integer
    timestamps(type: :utc_datetime)
  end

  def object_key(%__MODULE__{id: id}), do: "recordings/#{id}.mp4"
end
