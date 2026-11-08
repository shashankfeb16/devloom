defmodule Devloom.ChatTest do
  use Devloom.DataCase

  alias Devloom.Boards
  alias Devloom.Boards.Board
  alias Devloom.Chat
  alias Devloom.Chat.Message

  setup do
    %{board: Boards.get_default_board!()}
  end

  test "persists trimmed messages and multiline bodies", %{board: board} do
    attrs = attrs(%{sender_name: "  Sam  ", body: "  Ready to ship!\nTests are green.  "})

    assert {:ok, message} = Chat.create_message(board, attrs)
    assert message.sender_name == "Sam"
    assert message.body == "Ready to ship!\nTests are green."
    assert message.client_ref == attrs.client_ref
    assert message.board_id == board.id
    assert %DateTime{} = message.inserted_at
    assert Repo.get!(Message, message.id) == message
    assert Chat.list_messages(board) == [message]
  end

  test "rejects missing, blank, oversized, and malformed input without broadcasting", %{
    board: board
  } do
    Chat.subscribe(board)

    for field <- [:sender_name, :body], value <- [nil, "", " \t\n "] do
      assert {:error, changeset} = Chat.create_message(board, attrs(%{field => value}))
      assert changeset.action == :insert
      assert "can't be blank" in errors_on(changeset)[field]
    end

    assert {:error, changeset} =
             Chat.create_message(board, attrs(%{sender_name: String.duplicate("s", 51)}))

    assert "should be at most 50 character(s)" in errors_on(changeset).sender_name

    assert {:error, changeset} =
             Chat.create_message(board, attrs(%{body: String.duplicate("s", 4_001)}))

    assert "should be at most 4000 character(s)" in errors_on(changeset).body

    for ref <- [nil, "", "not-a-uuid"] do
      assert {:error, changeset} = Chat.create_message(board, attrs(%{client_ref: ref}))
      assert Map.has_key?(errors_on(changeset), :client_ref)
    end

    assert Chat.list_messages(board) == []
    refute_received {:message_created, _}
  end

  test "supports Unicode at the same character boundaries as the database", %{board: board} do
    assert {:ok, _message} =
             Chat.create_message(board, attrs(%{sender_name: String.duplicate("界", 50)}))

    assert {:error, changeset} =
             Chat.create_message(board, attrs(%{sender_name: String.duplicate("界", 51)}))

    assert Map.has_key?(errors_on(changeset), :sender_name)
  end

  test "only casts editable message attributes and scopes history to its board", %{board: board} do
    other = other_board()
    {:ok, foreign} = Chat.create_message(other, attrs())

    assert {:ok, message} =
             Chat.create_message(board, attrs(%{board_id: other.id, id: foreign.id}))

    assert message.board_id == board.id
    assert message.id != foreign.id
    assert Chat.list_messages(board) == [message]
    assert Chat.list_messages(other) == [foreign]
    assert Chat.list_messages(board, before_id: foreign.id) == []
  end

  test "publishes new persisted messages only to the matching board", %{board: board} do
    other = other_board()
    Chat.subscribe(board)
    {:ok, _foreign} = Chat.create_message(other, attrs())
    refute_received {:message_created, _}

    {:ok, message} = Chat.create_message(board, attrs())
    assert_receive {:message_created, ^message}
    assert Repo.get!(Message, message.id) == message
    refute_received {:message_created, _}
  end

  test "retries return the same message without a duplicate broadcast or replacement", %{
    board: board
  } do
    Chat.subscribe(board)
    attrs = attrs()
    assert {:ok, original} = Chat.create_message(board, attrs)
    assert_receive {:message_created, ^original}

    assert {:ok, ^original} =
             Chat.create_message(board, Map.put(attrs, :body, "A changed retry payload"))

    assert Chat.list_messages(board) == [original]
    refute_received {:message_created, _}

    assert {:ok, other_message} = Chat.create_message(other_board(), attrs)
    assert other_message.id != original.id
  end

  test "pages through newest, older, and catch-up history in chronological order", %{board: board} do
    messages = insert_messages(board, 55)
    ids = Enum.map(messages, & &1.id)

    assert message_ids(Chat.list_messages(board)) == Enum.drop(ids, 5)
    assert message_ids(Chat.list_messages(board, limit: 3)) == Enum.take(ids, -3)

    assert message_ids(Chat.list_messages(board, before_id: Enum.at(ids, 5), limit: 3)) ==
             ids |> Enum.drop(2) |> Enum.take(3)

    assert message_ids(Chat.list_messages(board, before_id: Integer.to_string(Enum.at(ids, 5)))) ==
             Enum.take(ids, 5)

    assert message_ids(Chat.list_messages(board, after_id: hd(ids), limit: 3)) ==
             ids |> Enum.drop(1) |> Enum.take(3)

    assert message_ids(Chat.list_messages(board, after_id: 0, limit: 3)) == Enum.take(ids, 3)
    assert message_ids(Chat.list_messages(board, after_id: "0", limit: 3)) == Enum.take(ids, 3)

    assert Chat.list_messages(board, after_id: List.last(ids)) == []
    assert Chat.list_messages(board, before_id: hd(ids)) == []
  end

  test "bounds query sizes and handles invalid pagination cursors safely", %{board: board} do
    insert_messages(board, 205)

    assert length(Chat.list_messages(board, limit: 10_000)) == 200

    for limit <- [0, -1, "all", nil] do
      assert length(Chat.list_messages(board, limit: limit)) == 50
    end

    assert Chat.list_messages(board, before_id: 0) == []

    for cursor <- ["bad-id", "", "1suffix", -1, 1.5, %{}, String.duplicate("9", 100)] do
      assert Chat.list_messages(board, before_id: cursor) == []
      assert Chat.list_messages(board, after_id: cursor) == []
    end

    assert Chat.list_messages(board, before_id: 2, after_id: 1) == []
  end

  test "missing boards cannot receive posts or broadcast a creation", %{board: board} do
    missing = %{board | id: 9_000_000_000}
    Chat.subscribe(missing)

    assert {:error, :not_found} = Chat.create_message(missing, attrs())
    refute_received {:message_created, _}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{sender_name: "Sam", body: "Ready to ship", client_ref: Ecto.UUID.generate()},
      overrides
    )
  end

  defp other_board do
    Repo.insert!(%Board{name: "Other project", slug: Ecto.UUID.generate()})
  end

  defp insert_messages(board, count) do
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        %{
          board_id: board.id,
          sender_name: "Sam",
          body: "Message #{index}",
          client_ref: Ecto.UUID.generate(),
          inserted_at: now
        }
      end

    {_count, messages} = Repo.insert_all(Message, rows, returning: true)
    messages
  end

  defp message_ids(messages), do: Enum.map(messages, & &1.id)
end
