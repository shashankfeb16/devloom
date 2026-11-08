defmodule Devloom.BoardsTest do
  use Devloom.DataCase

  alias Devloom.Boards
  alias Devloom.Boards.{Board, Column, WorkItem}

  setup do
    %{board: Boards.get_default_board!()}
  end

  test "default board is stable and never silently populates work", %{board: board} do
    assert Boards.get_default_board!().id == board.id
    assert Boards.list_work_items(board) == []
  end

  test "creates, reads, edits, and deletes a persisted work item", %{board: board} do
    assert {:ok, item} =
             Boards.create_work_item(board, %{
               title: "  Ship the shared board  ",
               description: "Work together in real time",
               status: "todo",
               type: "feature",
               priority: "high",
               labels: " Backend, Frontend, Backend, ",
               assignee: "  Sam  ",
               estimate: "5"
             })

    assert item.title == "Ship the shared board"
    assert item.labels == ["Backend", "Frontend"]
    assert item.assignee == "Sam"
    assert item.estimate == 5
    assert Boards.get_work_item(board, Integer.to_string(item.id)) == item

    assert {:ok, updated} =
             Boards.update_work_item(board, item, %{title: "Shipped", status: "done"})

    assert updated.title == "Shipped"
    assert updated.status == "done"
    assert updated.lock_version == item.lock_version + 1
    assert {:ok, _} = Boards.delete_work_item(board, updated)
    assert Boards.get_work_item(board, item.id) == nil
  end

  test "validates work item data without publishing unsuccessful changes", %{board: board} do
    Boards.subscribe(board)

    assert {:error, changeset} =
             Boards.create_work_item(board, %{title: " ", estimate: -1, priority: "surprise"})

    assert errors_on(changeset).title == ["can't be blank"]
    assert errors_on(changeset).priority == ["is invalid"]
    assert errors_on(changeset).estimate == ["must be greater than or equal to 0"]
    assert Boards.list_work_items(board) == []
    refute_received {:board_updated, _}

    assert {:error, changeset} =
             Boards.create_work_item(board, %{
               title: "A valid title",
               labels: [String.duplicate("x", 33)]
             })

    assert errors_on(changeset).labels == ["each label must be at most 32 characters"]
  end

  test "protects managed fields and scopes all operations to their board", %{board: board} do
    other = other_board()
    foreign = item(other, "Private work")

    assert {:ok, item} =
             Boards.create_work_item(board, %{
               title: "Scoped work",
               board_id: other.id,
               position: 999,
               lock_version: 99
             })

    assert item.board_id == board.id
    assert item.position == 0
    assert item.lock_version == 1
    assert Boards.get_work_item(board, foreign.id) == nil
    assert Boards.get_work_item(board, "not-an-id") == nil
    assert Boards.get_work_item(board, nil) == nil
    assert Boards.get_work_item(board, String.duplicate("9", 100)) == nil
    assert Boards.get_work_item(board, -1) == nil
    assert {:error, :not_found} = Boards.update_work_item(board, foreign, %{title: "Overwritten"})
    assert {:error, :not_found} = Boards.delete_work_item(board, foreign)
    assert {:error, :not_found} = Boards.move_work_item(board, foreign.id, "done")
    assert Boards.get_work_item(other, foreign.id).title == "Private work"
  end

  test "missing or blank required fields return validation errors on create and update", %{
    board: board
  } do
    item = item(board, "Keep this title", :todo)

    for field <- [:title, :status, :type, :priority], value <- [nil, "", "   "] do
      attrs = %{title: "Valid title"} |> Map.put(field, value)

      assert {:error, create_changeset} = Boards.create_work_item(board, attrs)
      assert Map.has_key?(errors_on(create_changeset), field)
      assert create_changeset.action == :insert

      assert {:error, update_changeset} = Boards.update_work_item(board, item, %{field => value})
      assert Map.has_key?(errors_on(update_changeset), field)
      assert update_changeset.action == :update
    end

    assert Boards.list_work_items(board) == [item]
  end

  test "normalizes and clears assignees and optional labels safely", %{board: board} do
    assert {:ok, item} =
             Boards.create_work_item(board, %{
               title: "Unassigned work",
               assignee: "   ",
               labels: nil
             })

    assert item.assignee == nil
    assert item.labels == []

    assert {:ok, assigned} = Boards.update_work_item(board, item, %{assignee: " Sam "})
    assert assigned.assignee == "Sam"
    assert {:ok, cleared} = Boards.update_work_item(board, assigned, %{assignee: nil})
    assert cleared.assignee == nil
    assert {:ok, assigned} = Boards.update_work_item(board, cleared, %{assignee: "Sam"})
    assert {:ok, cleared} = Boards.update_work_item(board, assigned, %{assignee: "   "})
    assert cleared.assignee == nil
  end

  test "stale editors cannot overwrite or delete another session's changes", %{board: board} do
    item = item(board, "Original")
    assert {:ok, current} = Boards.update_work_item(board, item, %{title: "Another session"})
    assert {:error, :stale} = Boards.update_work_item(board, item, %{title: "Old editor"})
    assert {:error, :stale} = Boards.delete_work_item(board, item)
    assert Boards.get_work_item(board, item.id) == current
  end

  test "reorders within a column, across columns, and into an empty column", %{board: board} do
    first = item(board, "First", :todo)
    second = item(board, "Second", :todo)
    third = item(board, "Third", :todo)
    destination = item(board, "Destination", :in_progress)

    assert {:ok, _} = Boards.move_work_item(board, third.id, "todo", first.id)
    assert column_ids(board, :todo) == [third.id, first.id, second.id]
    assert_positions(board, :todo)

    assert {:ok, moved} = Boards.move_work_item(board, first.id, "in_progress", destination.id)
    assert moved.status == "in_progress"
    assert column_ids(board, :in_progress) == [first.id, destination.id]
    assert column_ids(board, :todo) == [third.id, second.id]
    assert_positions(board, :todo)
    assert_positions(board, :in_progress)

    assert {:ok, moved} = Boards.move_work_item(board, first.id, "done")
    assert moved.position == 0
    assert column_ids(board, :done) == [first.id]
    assert column_ids(board, :in_progress) == [destination.id]

    assert {:ok, _} = Boards.move_work_item(board, third.id, "todo")
    assert column_ids(board, :todo) == [second.id, third.id]
    assert_positions(board, :todo)
  end

  test "rejects invalid destinations without changing the board", %{board: board} do
    first = item(board, "First", :todo)
    other_column = item(board, "Other column", :in_progress)
    other = other_board()
    foreign = item(other, "Foreign", :todo)

    assert {:error, :invalid_status} = Boards.move_work_item(board, first.id, "invented")
    assert {:error, :invalid_status} = Boards.move_work_item(board, first.id, nil)
    assert {:error, :invalid_target} = Boards.move_work_item(board, first.id, "todo", "bad-id")
    assert {:error, :invalid_target} = Boards.move_work_item(board, first.id, "todo", foreign.id)

    assert {:error, :invalid_target} =
             Boards.move_work_item(board, first.id, "todo", other_column.id)

    assert {:error, :not_found} = Boards.move_work_item(board, "bad-id", "todo")
    assert {:ok, same} = Boards.move_work_item(board, first.id, "todo", first.id)
    assert same == first
    assert column_ids(board, :todo) == [first.id]
  end

  test "moving and deleting items leave contiguous source and destination positions", %{
    board: board
  } do
    first = item(board, "First", :todo)
    second = item(board, "Second", :todo)
    third = item(board, "Third", :todo)

    assert {:ok, _} = Boards.update_work_item(board, second, %{status: "done"})
    assert column_ids(board, :todo) == [first.id, third.id]
    assert_positions(board, :todo)
    assert {:ok, _} = Boards.delete_work_item(board, first)
    assert column_ids(board, :todo) == [third.id]
    assert_positions(board, :todo)
  end

  test "filters by search, type, priority, and unassigned without SQL wildcard surprises", %{
    board: board
  } do
    assert {:ok, matching} =
             Boards.create_work_item(board, %{
               title: "Fix 100% of layout bugs",
               description: "The mobile screen",
               type: "bug",
               priority: "high"
             })

    assert {:ok, _} =
             Boards.create_work_item(board, %{
               title: "Review layouts",
               type: "task",
               priority: "low",
               assignee: "Sam"
             })

    assert Boards.list_work_items(board, %{"q" => "%"}) == [matching]

    assert Boards.list_work_items(board, %{"q" => "MOBILE", "type" => "bug", "priority" => "high"}) ==
             [matching]

    assert Boards.list_work_items(board, %{"assignee" => "unassigned"}) == [matching]
    assert Boards.list_work_items(board, %{"type" => "invalid"}) == []
    assert length(Boards.list_work_items(board, %{"type" => "all", "priority" => ""})) == 2
  end

  test "publishes board-scoped updates for every committed mutation", %{board: board} do
    board_id = board.id
    Boards.subscribe(board)
    item = item(board, "Live work")
    assert_receive {:board_updated, ^board_id}

    assert {:ok, updated} = Boards.update_work_item(board, item, %{title: "Updated live work"})
    assert_receive {:board_updated, ^board_id}

    assert {:ok, moved} = Boards.move_work_item(board, updated.id, "done")
    assert_receive {:board_updated, ^board_id}

    assert {:ok, _} = Boards.delete_work_item(board, moved)
    assert_receive {:board_updated, ^board_id}
  end

  test "loads samples once and never replaces or duplicates a populated board", %{board: board} do
    assert {:ok, items} = Boards.seed_sample_items(board)
    assert length(items) == 12
    assert Enum.sort(Enum.uniq(Enum.map(items, & &1.status))) == Enum.sort(WorkItem.statuses())
    assert Enum.all?(items, &is_nil(&1.assignee))
    assert {:error, :not_empty} = Boards.seed_sample_items(board)
    assert length(Boards.list_work_items(board)) == 12

    for status <- WorkItem.statuses(), do: assert_positions(board, status)
  end

  defp item(board, title, status \\ :backlog) do
    {:ok, item} = Boards.create_work_item(board, %{title: title, status: status})
    item
  end

  defp other_board do
    board = Repo.insert!(%Board{name: "Other project", slug: "other"})

    WorkItem.statuses()
    |> Enum.with_index()
    |> Enum.each(fn {key, position} ->
      Repo.insert!(%Column{board_id: board.id, key: key, title: key, position: position})
    end)

    board
  end

  defp column_ids(board, status) do
    board
    |> Boards.list_work_items()
    |> Enum.filter(&(&1.status == to_string(status)))
    |> Enum.map(& &1.id)
  end

  defp assert_positions(board, status) do
    items = board |> Boards.list_work_items() |> Enum.filter(&(&1.status == to_string(status)))
    assert Enum.map(items, & &1.position) == Enum.map(Enum.with_index(items), &elem(&1, 1))
  end
end
