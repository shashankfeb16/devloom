defmodule Devloom.Repo.Migrations.CreateDirectConversationsAndMessages do
  use Ecto.Migration

  def change do
    create table(:direct_conversations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :participant_one_id, references(:users, on_delete: :delete_all), null: false
      add :participant_two_id, references(:users, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :direct_conversations,
             [:workspace_id, :participant_one_id, :participant_two_id],
             name: :direct_conversations_workspace_pair_index
           )

    create index(:direct_conversations, [:participant_one_id])
    create index(:direct_conversations, [:participant_two_id])

    create constraint(:direct_conversations, :direct_conversations_ordered_pair,
             check: "participant_one_id < participant_two_id"
           )

    create table(:direct_messages) do
      add :conversation_id, references(:direct_conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :sender_name, :string, size: 50, null: false
      add :body, :text, null: false
      add :client_ref, :uuid, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:direct_messages, [:conversation_id, :id])
    create index(:direct_messages, [:user_id])
    create unique_index(:direct_messages, [:conversation_id, :client_ref])

    create constraint(:direct_messages, :direct_messages_body_length,
             check: "char_length(btrim(body)) BETWEEN 1 AND 4000"
           )

    create constraint(:direct_messages, :direct_messages_sender_name_length,
             check: "char_length(btrim(sender_name)) BETWEEN 1 AND 50"
           )
  end
end
