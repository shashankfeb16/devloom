defmodule Devloom.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :sender_name, :string, size: 50, null: false
      add :body, :text, null: false
      add :client_ref, :uuid, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:chat_messages, [:board_id, :id])
    create unique_index(:chat_messages, [:board_id, :client_ref])

    create constraint(:chat_messages, :chat_messages_sender_name_length,
             check: "char_length(btrim(sender_name)) BETWEEN 1 AND 50"
           )

    create constraint(:chat_messages, :chat_messages_body_length,
             check: "char_length(btrim(body)) BETWEEN 1 AND 4000"
           )
  end
end
