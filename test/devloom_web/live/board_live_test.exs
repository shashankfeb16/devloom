defmodule DevloomWeb.BoardLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Devloom.Boards

  setup do
    %{board: Boards.get_default_board!()}
  end

  test "an empty workspace has every workflow column and an explicit sample action", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#kanban-board[data-view='board']")
    assert has_element?(view, "#empty-board")
    assert has_element?(view, "#load-sample-items")
    assert has_element?(view, "#total-items[data-count='0']")

    for status <- ~w(backlog todo in_progress in_review done) do
      assert has_element?(view, "#column-#{status}")
      assert has_element?(view, "#items-#{status}[phx-update='stream']")
      assert has_element?(view, "#add-item-#{status}")
    end
  end

  test "creating an item validates input and persists all editable fields", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#new-work-item") |> render_click()
    assert has_element?(view, "#work-item-dialog[role='dialog']")

    view
    |> form("#work-item-form", work_item: %{title: ""})
    |> render_submit()

    assert has_element?(view, "#work-item-form")
    assert Boards.list_work_items(board) == []

    view
    |> form("#work-item-form",
      work_item: %{
        title: "Support keyboard navigation",
        description: "Make work items accessible to everyone.",
        status: "todo",
        type: "feature",
        priority: "high",
        estimate: "5",
        assignee: "Alex",
        labels: "Accessibility, Frontend"
      }
    )
    |> render_submit()

    [item] = Boards.list_work_items(board)
    assert item.title == "Support keyboard navigation"
    assert item.description == "Make work items accessible to everyone."
    assert item.status == "todo"
    assert item.type == :feature
    assert item.priority == :high
    assert item.estimate == 5
    assert item.assignee == "Alex"
    assert item.labels == ["Accessibility", "Frontend"]
    refute has_element?(view, "#work-item-dialog")
    refute has_element?(view, "#empty-board")
    assert has_element?(view, "#items-todo #work-item-#{item.id}")
    assert has_element?(view, "#total-items[data-count='1']")
  end

  test "adding from a column prefills its status and closing discards a draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#add-item-in_review") |> render_click()

    assert has_element?(
             view,
             "#work-item-form select[name='work_item[status]'] option[value='in_review'][selected]"
           )

    view |> element("#close-work-item") |> render_click()
    refute has_element?(view, "#work-item-dialog")
    assert has_element?(view, "#total-items[data-count='0']")
  end

  test "editing updates the item and its streamed column", %{conn: conn, board: board} do
    item = create_item(board, %{title: "Original title", labels: ["Backend"]})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#edit-item-#{item.id}") |> render_click()

    assert has_element?(
             view,
             "#work-item-form input[name='work_item[title]'][value='Original title']"
           )

    view
    |> form("#work-item-form",
      work_item: %{title: "Updated title", status: "in_progress", labels: "Backend, API"}
    )
    |> render_submit()

    updated = Boards.get_work_item(board, item.id)
    assert updated.title == "Updated title"
    assert updated.status == "in_progress"
    assert updated.labels == ["Backend", "API"]
    assert has_element?(view, "#items-in_progress #work-item-#{item.id}")
    refute has_element?(view, "#items-backlog #work-item-#{item.id}")
    refute has_element?(view, "#work-item-dialog")
  end

  test "deletion requires confirmation and can be cancelled", %{conn: conn, board: board} do
    item = create_item(board)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#edit-item-#{item.id}") |> render_click()
    view |> element("#delete-work-item") |> render_click()
    assert has_element?(view, "#confirm-delete-work-item")
    assert Boards.get_work_item(board, item.id)

    view |> element("#cancel-delete-work-item") |> render_click()
    refute has_element?(view, "#confirm-delete-work-item")
    assert Boards.get_work_item(board, item.id)

    view |> element("#delete-work-item") |> render_click()
    view |> element("#confirm-delete-work-item") |> render_click()

    refute Boards.get_work_item(board, item.id)
    refute has_element?(view, "#work-item-#{item.id}")
    refute has_element?(view, "#work-item-dialog")
    assert has_element?(view, "#empty-board")
  end

  test "drag events persist moves and refresh a second connected session", %{
    conn: conn,
    board: board
  } do
    item = create_item(board)
    {:ok, first, _html} = live(conn, ~p"/")
    {:ok, second, _html} = live(build_conn(), ~p"/")

    render_hook(first, "move_item", %{id: item.id, status: "done", before_id: nil})

    assert Boards.get_work_item(board, item.id).status == "done"
    assert has_element?(first, "#items-done #work-item-#{item.id}")
    assert has_element?(second, "#items-done #work-item-#{item.id}")
    refute has_element?(second, "#items-backlog #work-item-#{item.id}")
    assert has_element?(second, "#count-done[data-count='1']")
  end

  test "drag events reorder items within a column and reject invalid destinations", %{
    conn: conn,
    board: board
  } do
    first = create_item(board, %{title: "First"})
    second = create_item(board, %{title: "Second"})
    third = create_item(board, %{title: "Third"})
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "move_item", %{id: third.id, status: "backlog", before_id: first.id})

    assert Enum.map(Boards.list_work_items(board), & &1.id) == [third.id, first.id, second.id]
    assert has_element?(view, "#items-backlog > #work-item-#{third.id}:first-of-type")

    render_hook(view, "move_item", %{id: first.id, status: "unknown", before_id: nil})

    assert Boards.get_work_item(board, first.id).status == "backlog"
    assert has_element?(view, "#work-item-#{first.id}")
  end

  test "create, update and delete propagate to another open board", %{conn: conn, board: board} do
    {:ok, first, _html} = live(conn, ~p"/")
    {:ok, second, _html} = live(build_conn(), ~p"/")

    first |> element("#new-work-item") |> render_click()
    first |> form("#work-item-form", work_item: %{title: "Shared work"}) |> render_submit()

    [item] = Boards.list_work_items(board)
    assert has_element?(second, "#work-item-#{item.id}")

    first |> element("#edit-item-#{item.id}") |> render_click()

    first
    |> form("#work-item-form", work_item: %{title: "Shared work updated", status: "in_review"})
    |> render_submit()

    assert has_element?(second, "#items-in_review #work-item-#{item.id}")
    assert has_element?(second, "#edit-item-#{item.id}", "Shared work updated")

    first |> element("#edit-item-#{item.id}") |> render_click()
    first |> element("#delete-work-item") |> render_click()
    first |> element("#confirm-delete-work-item") |> render_click()

    refute has_element?(second, "#work-item-#{item.id}")
    assert has_element?(second, "#total-items[data-count='0']")
  end

  test "search and filters narrow streamed items without changing the board totals", %{
    conn: conn,
    board: board
  } do
    matching = create_item(board, %{title: "Fix keyboard focus", type: :bug, priority: :high})
    other = create_item(board, %{title: "Document the API", type: :task, priority: :low})
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#board-filters", filters: %{q: "keyboard", type: "bug", priority: "high"})
    |> render_change()

    assert has_element?(view, "#work-item-#{matching.id}")
    refute has_element?(view, "#work-item-#{other.id}")
    assert has_element?(view, "#total-items[data-count='2']")
    assert has_element?(view, "#visible-items[data-count='1']")

    view |> element("#clear-filters") |> render_click()

    assert has_element?(view, "#work-item-#{matching.id}")
    assert has_element?(view, "#work-item-#{other.id}")
    assert has_element?(view, "#visible-items[data-count='2']")
  end

  test "the unassigned filter excludes assigned work", %{conn: conn, board: board} do
    unassigned = create_item(board)
    assigned = create_item(board, %{assignee: "Alex"})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#board-filters", filters: %{assignee: "unassigned"}) |> render_change()

    assert has_element?(view, "#work-item-#{unassigned.id}")
    refute has_element?(view, "#work-item-#{assigned.id}")
  end

  test "a remotely deleted open item displays a notice without crashing", %{
    conn: conn,
    board: board
  } do
    item = create_item(board)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#edit-item-#{item.id}") |> render_click()

    {:ok, _deleted} = Boards.delete_work_item(board, item)

    assert has_element?(view, "#editor-notice")
    assert has_element?(view, "#work-item-dialog")
    refute has_element?(view, "#kanban-board #work-item-#{item.id}")

    view |> element("#close-work-item") |> render_click()
    refute has_element?(view, "#work-item-dialog")
  end

  test "an old editor cannot overwrite a change saved by another session", %{
    conn: conn,
    board: board
  } do
    item = create_item(board)
    {:ok, first, _html} = live(conn, ~p"/")
    {:ok, second, _html} = live(build_conn(), ~p"/")

    first |> element("#edit-item-#{item.id}") |> render_click()
    second |> element("#edit-item-#{item.id}") |> render_click()

    first
    |> form("#work-item-form", work_item: %{title: "Saved by another teammate"})
    |> render_submit()

    second
    |> form("#work-item-form", work_item: %{title: "An outdated draft"})
    |> render_submit()

    assert Boards.get_work_item(board, item.id).title == "Saved by another teammate"
    assert has_element?(second, "#work-item-dialog")
    assert has_element?(second, "#editor-notice")
  end

  test "board and list views show the same persistent items", %{conn: conn, board: board} do
    item = create_item(board)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#view-list") |> render_click()
    assert has_element?(view, "#kanban-board[data-view='list']")
    assert has_element?(view, "#work-item-#{item.id}")

    view |> element("#view-board") |> render_click()
    assert has_element?(view, "#kanban-board[data-view='board']")
    assert has_element?(view, "#work-item-#{item.id}")
  end

  test "example work is loaded only on request and remains unchanged on refresh", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert Boards.list_work_items(board) == []

    view |> element("#load-sample-items") |> render_click()
    items = Boards.list_work_items(board)
    assert length(items) > 0
    refute has_element?(view, "#empty-board")

    {:ok, refreshed, _html} = live(build_conn(), ~p"/")
    assert Boards.list_work_items(board) == items

    for item <- items do
      assert has_element?(refreshed, "#work-item-#{item.id}")
    end
  end

  defp create_item(board, attrs \\ %{}) do
    attrs =
      Map.merge(%{title: "A work item", status: "backlog", type: :task, priority: :medium}, attrs)

    {:ok, item} = Boards.create_work_item(board, attrs)
    item
  end
end
