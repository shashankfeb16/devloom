defmodule Devloom.DirectMessages.Conversation do
  @moduledoc "A private conversation between two accounts in one workspace."
  use Ecto.Schema

  schema "direct_conversations" do
    belongs_to :workspace, Devloom.Workspaces.Workspace
    belongs_to :participant_one, Devloom.Accounts.User
    belongs_to :participant_two, Devloom.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
