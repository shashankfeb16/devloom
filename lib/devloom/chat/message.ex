defmodule Devloom.Chat.Message do
  @moduledoc "A persisted message with a guest-provided display name."
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_messages" do
    field :sender_name, :string
    field :body, :string
    field :client_ref, Ecto.UUID

    belongs_to :board, Devloom.Boards.Board
    belongs_to :user, Devloom.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:sender_name, :body, :client_ref])
    |> update_change(:sender_name, &String.trim/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:sender_name, :body, :client_ref])
    |> validate_length(:sender_name, min: 1, max: 50, count: :codepoints)
    |> validate_length(:body, min: 1, max: 4_000, count: :codepoints)
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :client_ref])
    |> check_constraint(:sender_name, name: :chat_messages_sender_name_length)
    |> check_constraint(:body, name: :chat_messages_body_length)
  end
end
