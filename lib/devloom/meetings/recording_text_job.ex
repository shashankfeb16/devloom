defmodule Devloom.Meetings.RecordingTextJob do
  @moduledoc false
  use Ecto.Schema

  schema "recording_text_jobs" do
    belongs_to :recording, Devloom.Meetings.Recording, type: Ecto.UUID
    field :kind, Ecto.Enum, values: [:transcript, :summary]
    field :status, Ecto.Enum, values: [:queued, :running, :ready, :failed]
    field :run_id, Ecto.UUID
    field :result, :map
    field :error, :string
    timestamps(type: :utc_datetime)
  end
end
