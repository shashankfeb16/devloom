defmodule Devloom.DirectMessages.Message do
  @moduledoc "A private message with its authenticated author's name at send time."
  use Ecto.Schema
  import Ecto.Changeset

  schema "direct_messages" do
    field :sender_name, :string
    field :body, :string
    field :client_ref, Ecto.UUID
    belongs_to :conversation, Devloom.DirectMessages.Conversation
    belongs_to :user, Devloom.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :client_ref])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body, :client_ref])
    |> validate_length(:body, min: 1, max: 4_000, count: :codepoints)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:conversation_id, :client_ref])
    |> check_constraint(:body, name: :direct_messages_body_length)
  end
end
