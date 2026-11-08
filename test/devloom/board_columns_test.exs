defmodule Devloom.BoardColumnsTest do
  use Devloom.DataCase

  alias Devloom.Boards
  alias Devloom.Boards.Board

  setup do
    %{board: Boards.get_default_board!()}
  end

  test "new boards have the original five columns with stable string keys", %{board: board} do
    columns = Boards.list_columns(board)
    assert Enum.map(columns, & &1.key) == ~w(backlog todo in_progress in_review done)

    assert Enum.map(columns, & &1.title) == [
             "Backlog",
             "To do",
             "In progress",
             "In review",
             "Done"
           ]

    assert Enum.filter(columns, & &1.completed) |> Enum.map(& &1.key) == ["done"]
    assert Enum.map(columns, & &1.color) == [:neutral, :blue, :amber, :purple, :green]
    assert Boards.get_default_board!().id == board.id
    assert Boards.list_columns(board) == columns
    assert Boards.list_work_items(board) == []
  end

  test "creates a column while keeping keys and ordering under server control", %{board: board} do
    assert {:ok, column} =
             Boards.create_column(board, %{
               title: "  QA testing  ",
               description: "  Ready for testing  ",
               color: "rose",
               completed: "false",
               key: "done",
               board_id: -1,
               position: 0,
               lock_version: 42
             })

    assert column.title == "QA testing"
    assert column.description == "Ready for testing"
    assert column.color == :rose
    assert column.completed == false
    assert column.position == 5
    assert column.lock_version == 1
    assert column.board_id == board.id
    assert Regex.match?(~r/^column_[0-9a-f]{32}$/, column.key)
    assert Boards.get_column(board, Integer.to_string(column.id)) == column
  end

  test "renames and configures columns without changing the cards' stable statuses", %{
    board: board
  } do
    column = column(board, "todo")
    {:ok, item} = Boards.create_work_item(board, %{title: "Keep me", status: column.key})

    assert {:ok, updated} =
             Boards.update_column(board, column, %{
               title: "Ready for development",
               description: "Selected for this week",
               color: "purple",
               completed: true,
               key: "forged",
               position: 99
             })

    assert updated.title == "Ready for development"
    assert updated.key == "todo"
    assert updated.position == 1
    assert updated.color == :purple
    assert updated.completed
    assert Boards.get_work_item(board, item.id) == item
    assert {:error, :stale} = Boards.update_column(board, column, %{title: "Old editor"})
    assert {:error, :stale} = Boards.delete_column(board, column)
  end

  test "rejects invalid column settings and duplicate names without publishing", %{board: board} do
    Boards.subscribe(board)

    for attrs <- [
          %{title: nil},
          %{title: " "},
          %{title: String.duplicate("a", 41)},
          %{title: "QA", description: String.duplicate("a", 101)},
          %{title: "QA", color: "invented"},
          %{title: "QA", color: ""},
          %{title: "QA", color: nil},
          %{title: "QA", completed: nil}
        ] do
      assert {:error, %Ecto.Changeset{}} = Boards.create_column(board, attrs)
    end

    assert {:error, duplicate} = Boards.create_column(board, %{title: " BACKLOG "})
    assert errors_on(duplicate).title == ["a column with this name already exists"]

    assert {:error, duplicate} =
             Boards.update_column(board, column(board, "todo"), %{title: "dOnE"})

    assert errors_on(duplicate).title == ["a column with this name already exists"]
    assert length(Boards.list_columns(board)) == 5
    refute_received {:board_updated, _}
  end

  test "moves columns left and right while preserving all work items", %{board: board} do
    {:ok, item} = Boards.create_work_item(board, %{title: "Ordered work", status: "todo"})
    review = column(board, "in_review")

    assert {:ok, moved} = Boards.move_column(board, review.id, "left")
    assert moved.position == 2
    assert column_keys(board) == ~w(backlog todo in_review in_progress done)
    assert {:ok, _} = Boards.move_column(board, review.id, "right")
    assert column_keys(board) == ~w(backlog todo in_progress in_review done)
    assert Boards.get_work_item(board, item.id) == item
    assert {:ok, _} = Boards.move_column(board, column(board, "backlog").id, "left")
    assert {:ok, _} = Boards.move_column(board, column(board, "done").id, "right")
    assert {:error, :invalid_direction} = Boards.move_column(board, review.id, "up")
    assert_column_positions(board)
  end

  test "deletes an empty default column permanently without resurrecting it on reconnect", %{
    board: board
  } do
    deleted = column(board, "in_review")
    assert {:ok, result} = Boards.delete_column(board, deleted)
    assert result.id == deleted.id
    assert Boards.get_column(board, deleted.id) == nil
    assert column_keys(board) == ~w(backlog todo in_progress done)
    assert Boards.get_default_board!().id == board.id
    assert column_keys(board) == ~w(backlog todo in_progress done)
    assert_column_positions(board)
  end

  test "never deletes the last column", %{board: board} do
    for key <- ~w(backlog todo in_progress in_review) do
      assert {:ok, _} = Boards.delete_column(board, column(board, key))
    end

    last = column(board, "done")
    assert {:error, :last_column} = Boards.delete_column(board, last)
    assert Boards.list_columns(board) == [last]

    assert {:ok, item} =
             Boards.create_work_item(board, %{title: "Default to the remaining column"})

    assert item.status == "done"
  end

  test "requires a valid destination before deleting a column containing cards", %{board: board} do
    source = column(board, "todo")
    {:ok, item} = Boards.create_work_item(board, %{title: "Do not lose me", status: source.key})
    other = Repo.insert!(%Board{name: "Other project", slug: "other"})
    {:ok, foreign} = Boards.create_column(other, %{title: "Foreign destination"})

    assert {:error, :destination_required} = Boards.delete_column(board, source)
    assert {:error, :destination_required} = Boards.delete_column(board, source, "")
    assert {:error, :invalid_destination} = Boards.delete_column(board, source, source.id)
    assert {:error, :invalid_destination} = Boards.delete_column(board, source, foreign.id)
    assert {:error, :invalid_destination} = Boards.delete_column(board, source, "not-an-id")
    assert Boards.get_column(board, source.id) == source
    assert Boards.get_work_item(board, item.id) == item
  end

  test "deleting a populated column appends its cards in order and invalidates old editors", %{
    board: board
  } do
    source = column(board, "todo")
    destination = column(board, "in_progress")
    existing = create_items(board, destination.key, ["Existing one", "Existing two"])
    moved = create_items(board, source.key, ["Move one", "Move two", "Move three"])

    assert {:ok, result} = Boards.delete_column(board, source, destination.id)
    assert result.id == source.id
    assert Boards.get_column(board, source.id) == nil

    items = Boards.list_work_items(board) |> Enum.filter(&(&1.status == destination.key))
    assert Enum.map(items, & &1.id) == Enum.map(existing ++ moved, & &1.id)
    assert Enum.map(items, & &1.position) == [0, 1, 2, 3, 4]

    for original <- moved do
      current = Boards.get_work_item(board, original.id)
      assert current.lock_version == original.lock_version + 1
      assert DateTime.compare(current.updated_at, original.updated_at) in [:eq, :gt]
      assert {:error, :stale} = Boards.update_work_item(board, original, %{title: "Stale editor"})
    end

    assert {:error, :invalid_status} = Boards.move_work_item(board, hd(moved).id, source.key)

    assert {:error, changeset} =
             Boards.create_work_item(board, %{title: "Deleted destination", status: source.key})

    assert Map.has_key?(errors_on(changeset), :status)
  end

  test "new cards use the first configured column when no status was provided", %{board: board} do
    {:ok, custom} = Boards.create_column(board, %{title: "Intake"})

    for _ <- 1..5, do: Boards.move_column(board, custom.id, "left")

    assert {:ok, item} = Boards.create_work_item(board, %{title: "Enter through intake"})
    assert item.status == custom.key
    assert {:ok, updated} = Boards.update_work_item(board, item, %{status: "todo"})
    assert updated.status == "todo"
    assert {:ok, moved} = Boards.move_work_item(board, item.id, custom.key)
    assert moved.status == custom.key
  end

  test "column IDs and card statuses cannot cross board boundaries", %{board: board} do
    other = Repo.insert!(%Board{name: "Other project", slug: "other"})
    {:ok, foreign} = Boards.create_column(other, %{title: "Private workflow"})
    {:ok, item} = Boards.create_work_item(board, %{title: "Board scoped"})

    assert Boards.get_column(board, foreign.id) == nil
    assert Boards.get_column(board, String.duplicate("9", 100)) == nil
    assert {:error, :not_found} = Boards.update_column(board, foreign, %{title: "Overwrite"})
    assert {:error, :not_found} = Boards.move_column(board, foreign.id, "left")
    assert {:error, :not_found} = Boards.delete_column(board, foreign)
    assert {:error, :invalid_status} = Boards.move_work_item(board, item.id, foreign.key)
    assert {:error, changeset} = Boards.update_work_item(board, item, %{status: foreign.key})
    assert Map.has_key?(errors_on(changeset), :status)

    assert {:error, changeset} =
             Boards.create_work_item(board, %{title: "Invalid scope", status: foreign.key})

    assert Map.has_key?(errors_on(changeset), :status)
  end

  test "example work adapts to deleted defaults without restoring columns", %{board: board} do
    assert {:ok, _} = Boards.delete_column(board, column(board, "todo"))
    assert {:ok, _} = Boards.delete_column(board, column(board, "done"))
    keys = column_keys(board)

    assert {:ok, items} = Boards.seed_sample_items(board)
    assert length(items) == 12
    assert Enum.all?(items, &(&1.status in keys))
    assert column_keys(board) == keys
  end

  test "publishes committed column changes to board subscribers", %{board: board} do
    Boards.subscribe(board)
    board_id = board.id
    assert {:ok, column} = Boards.create_column(board, %{title: "QA"})
    assert_receive {:board_updated, ^board_id}
    assert {:ok, column} = Boards.update_column(board, column, %{title: "Quality assurance"})
    assert_receive {:board_updated, ^board_id}
    assert {:ok, column} = Boards.move_column(board, column.id, "left")
    assert_receive {:board_updated, ^board_id}
    assert {:ok, _} = Boards.delete_column(board, column)
    assert_receive {:board_updated, ^board_id}
  end

  defp column(board, key), do: Enum.find(Boards.list_columns(board), &(&1.key == key))
  defp column_keys(board), do: Enum.map(Boards.list_columns(board), & &1.key)

  defp create_items(board, key, titles) do
    Enum.map(titles, fn title ->
      {:ok, item} = Boards.create_work_item(board, %{title: title, status: key})
      item
    end)
  end

  defp assert_column_positions(board) do
    positions = Enum.map(Boards.list_columns(board), & &1.position)
    assert positions == Enum.to_list(0..(length(positions) - 1))
  end
end
