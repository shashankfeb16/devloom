defmodule DevloomWeb.BoardColumnsLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Devloom.Boards

  setup %{conn: conn} do
    context = setup_workspace(conn)
    Map.put(context, :columns, Boards.list_columns(context.scope))
  end

  test "column settings expose drag handles for the existing workflow", %{
    conn: conn,
    columns: columns
  } do
    {:ok, view, _html} = live(conn, board_path(conn))
    open_settings(view)

    assert has_element?(view, "#column-settings-dialog[role='dialog']")
    assert has_element?(view, "#column-settings-list[phx-update='stream']")

    for column <- columns do
      assert has_element?(view, "#column-setting-#{column.id}")
      assert has_element?(view, "#edit-column-#{column.id}")
      assert has_element?(view, "#delete-column-#{column.id}")
      assert has_element?(view, "#drag-column-#{column.id}[data-column-drag-handle]")
    end

    assert has_element?(view, "#column-settings-list[phx-hook='ColumnReorder']")
    refute has_element?(view, "[title='Move earlier'], [title='Move later']")

    view |> element("#close-column-settings") |> render_click()
    refute has_element?(view, "#column-settings-dialog")
  end

  test "a custom column validates input and keeps its settings after remount", %{
    conn: conn,
    board: board,
    columns: original_columns
  } do
    {:ok, view, _html} = live(conn, board_path(conn))
    open_settings(view)

    view |> form("#column-form", column: %{title: ""}) |> render_submit()
    assert Boards.list_columns(board) == original_columns
    assert has_element?(view, "#column-form")

    view
    |> form("#column-form",
      column: %{
        title: "Quality assurance",
        description: "Ready for testing",
        color: "rose",
        completed: false
      }
    )
    |> render_submit()

    column = column_named(board, "Quality assurance")
    assert column.description == "Ready for testing"
    assert column.color == :rose
    refute column.completed
    assert has_element?(view, "#column-settings-dialog")
    assert has_element?(view, "#column-setting-#{column.id}")
    assert has_element?(view, "#column-#{column.key}")
    assert has_element?(view, "#items-#{column.key}[phx-update='stream']")
    assert has_element?(view, "#count-#{column.key}[data-count='0']")

    {:ok, remounted, _html} = live(second_conn(conn), board_path(conn))
    assert Boards.get_column(board, column.id) == column
    assert has_element?(remounted, "#column-#{column.key}")
    assert has_element?(remounted, "#heading-#{column.key}", "Quality assurance")
  end

  test "renaming a column preserves its key and its existing work items", %{
    conn: conn,
    board: board,
    columns: columns
  } do
    column = hd(columns)
    item = create_item(board, %{status: column.key})
    {:ok, view, _html} = live(conn, board_path(conn))
    open_settings(view)
    view |> element("#edit-column-#{column.id}") |> render_click()

    view
    |> form("#column-form",
      column: %{
        title: "Discovery",
        description: "Work to explore together",
        color: "purple"
      }
    )
    |> render_submit()

    updated = Boards.get_column(board, column.id)
    assert updated.key == column.key
    assert updated.title == "Discovery"
    assert updated.description == "Work to explore together"
    assert updated.color == :purple
    assert Boards.get_work_item(board, item.id).status == column.key
    assert has_element?(view, "#heading-#{column.key}", "Discovery")
    assert has_element?(view, "#items-#{column.key} #work-item-#{item.id}")
  end

  test "reordering a column is saved and appears in another connected session", %{
    conn: conn,
    board: board,
    columns: [first, second | remaining]
  } do
    {:ok, first_view, _html} = live(conn, board_path(conn))
    {:ok, second_view, _html} = live(second_conn(conn), board_path(conn))
    open_settings(first_view)
    render_hook(first_view, "reorder_column", %{id: first.id, before_id: hd(remaining).id})

    assert Enum.map(Boards.list_columns(board), & &1.id) ==
             Enum.map([second, first | remaining], & &1.id)

    assert has_element?(
             first_view,
             "#kanban-board > #column-#{second.key} + #column-#{first.key}"
           )

    assert has_element?(
             second_view,
             "#kanban-board > #column-#{second.key} + #column-#{first.key}"
           )

    {:ok, remounted, _html} = live(second_conn(conn), board_path(conn))
    assert has_element?(remounted, "#kanban-board > #column-#{second.key} + #column-#{first.key}")

    render_hook(first_view, "reorder_column", %{id: first.id, before_id: second.id})
    assert hd(Boards.list_columns(board)).id == first.id

    assert has_element?(
             second_view,
             "#kanban-board > #column-#{first.key} + #column-#{second.key}"
           )
  end

  test "drag moves can skip columns, append, and reject missing destinations", %{
    conn: conn,
    board: board,
    columns: columns
  } do
    {:ok, view, _html} = live(conn, board_path(conn))
    open_settings(view)
    first = hd(columns)
    last = List.last(columns)

    render_hook(view, "reorder_column", %{id: last.id, before_id: first.id})
    assert hd(Boards.list_columns(board)).id == last.id
    assert has_element?(view, "#column-settings-list > #column-setting-#{last.id}:first-child")

    render_hook(view, "reorder_column", %{id: last.id, before_id: nil})
    assert Enum.map(Boards.list_columns(board), & &1.id) == Enum.map(columns, & &1.id)
    assert has_element?(view, "#column-settings-list > #column-setting-#{last.id}:last-child")

    render_hook(view, "reorder_column", %{id: first.id, before_id: "invalid"})
    assert Enum.map(Boards.list_columns(board), & &1.id) == Enum.map(columns, & &1.id)
    assert has_element?(view, "#column-settings-notice")
  end

  test "custom columns are available for new items, editing and drag moves", %{
    conn: conn,
    board: board
  } do
    column = create_column(board, %{title: "Testing"})
    existing = create_item(board)
    {:ok, view, _html} = live(conn, board_path(conn))

    view |> element("#add-item-#{column.key}") |> render_click()

    assert has_element?(
             view,
             "#work-item-form select[name='work_item[status]'] option[value='#{column.key}'][selected]"
           )

    view
    |> form("#work-item-form", work_item: %{title: "A test plan", status: column.key})
    |> render_submit()

    created = Enum.find(Boards.list_work_items(board), &(&1.title == "A test plan"))
    assert created.status == column.key
    assert has_element?(view, "#items-#{column.key} #work-item-#{created.id}")

    render_hook(view, "move_item", %{id: existing.id, status: column.key, before_id: created.id})
    assert Boards.get_work_item(board, existing.id).status == column.key
    assert has_element?(view, "#items-#{column.key} #work-item-#{existing.id}")

    view |> element("#edit-item-#{existing.id}") |> render_click()
    view |> form("#work-item-form", work_item: %{status: "done"}) |> render_submit()
    assert Boards.get_work_item(board, existing.id).status == "done"
    assert has_element?(view, "#items-done #work-item-#{existing.id}")
  end

  test "deleting an empty column requires confirmation and updates other sessions", %{
    conn: conn,
    board: board
  } do
    column = create_column(board, %{title: "Optional stage"})
    {:ok, view, _html} = live(conn, board_path(conn))
    {:ok, other, _html} = live(second_conn(conn), board_path(conn))
    open_settings(view)

    view |> element("#delete-column-#{column.id}") |> render_click()
    assert has_element?(view, "#column-delete-confirmation")
    assert Boards.get_column(board, column.id)

    view |> element("#cancel-delete-column") |> render_click()
    refute has_element?(view, "#column-delete-confirmation")
    assert Boards.get_column(board, column.id)

    view |> element("#delete-column-#{column.id}") |> render_click()
    view |> form("#column-delete-form") |> render_submit()

    refute Boards.get_column(board, column.id)
    refute has_element?(view, "#column-setting-#{column.id}")
    refute has_element?(view, "#column-#{column.key}")
    refute has_element?(other, "#column-#{column.key}")
  end

  test "deleting a populated column requires a destination and preserves item order", %{
    conn: conn,
    board: board
  } do
    source = create_column(board, %{title: "Testing"})
    destination = column_named(board, "To do")
    existing = create_item(board, %{title: "Existing destination item", status: destination.key})
    first = create_item(board, %{title: "First source item", status: source.key})
    second = create_item(board, %{title: "Second source item", status: source.key})
    {:ok, view, _html} = live(conn, board_path(conn))
    {:ok, other, _html} = live(second_conn(conn), board_path(conn))
    open_settings(view)
    view |> element("#delete-column-#{source.id}") |> render_click()

    assert has_element?(view, "#confirm-delete-column[disabled]")
    assert Boards.get_column(board, source.id)
    assert Boards.get_work_item(board, first.id).status == source.key

    view
    |> form("#column-delete-form", column_delete: %{destination_id: to_string(destination.id)})
    |> render_change()

    refute has_element?(view, "#confirm-delete-column[disabled]")

    view
    |> form("#column-delete-form", column_delete: %{destination_id: to_string(destination.id)})
    |> render_submit()

    refute Boards.get_column(board, source.id)

    items = Boards.list_work_items(board)
    assert length(items) == 3

    assert items
           |> Enum.filter(&(&1.status == destination.key))
           |> Enum.map(& &1.id) == [existing.id, first.id, second.id]

    for item <- [existing, first, second] do
      assert has_element?(view, "#items-#{destination.key} #work-item-#{item.id}")
      assert has_element?(other, "#items-#{destination.key} #work-item-#{item.id}")
    end

    refute has_element?(other, "#column-#{source.key}")
    assert has_element?(other, "#total-items[data-count='3']")
  end

  test "the final column cannot be deleted", %{conn: conn, board: board, columns: columns} do
    [remaining | to_delete] = columns

    for column <- to_delete do
      {:ok, _deleted} = Boards.delete_column(board, Boards.get_column(board, column.id))
    end

    {:ok, view, _html} = live(conn, board_path(conn))
    open_settings(view)

    assert has_element?(view, "#delete-column-#{remaining.id}[disabled]")
    assert has_element?(view, "#drag-column-#{remaining.id}[disabled]")
    assert Boards.list_columns(board) == [Boards.get_column(board, remaining.id)]
    assert has_element?(view, "#column-#{remaining.key}")
  end

  test "completion counts follow configurable completed columns", %{conn: conn, board: board} do
    complete = create_column(board, %{title: "Released", color: "green", completed: true})
    first = create_item(board)
    second = create_item(board, %{title: "Another item"})
    {:ok, view, _html} = live(conn, board_path(conn))

    assert has_element?(view, "#completed-items[data-count='0']")
    render_hook(view, "move_item", %{id: first.id, status: complete.key, before_id: nil})
    assert has_element?(view, "#completed-items[data-count='1']")

    render_hook(view, "move_item", %{id: second.id, status: "done", before_id: nil})
    assert has_element?(view, "#completed-items[data-count='2']")

    open_settings(view)
    view |> element("#edit-column-#{complete.id}") |> render_click()
    view |> form("#column-form", column: %{completed: false}) |> render_submit()

    refute Boards.get_column(board, complete.id).completed
    assert has_element?(view, "#completed-items[data-count='1']")
    assert has_element?(view, "#items-#{complete.key} #work-item-#{first.id}")
  end

  test "column creation and renaming arrive in another open board and its status options", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, board_path(conn))
    {:ok, other, _html} = live(second_conn(conn), board_path(conn))
    open_settings(view)
    view |> form("#column-form", column: %{title: "Testing", color: "amber"}) |> render_submit()

    column = column_named(board, "Testing")
    assert has_element?(other, "#column-#{column.key}")

    other |> element("#new-work-item") |> render_click()

    assert has_element?(
             other,
             "#work-item-form select[name='work_item[status]'] option[value='#{column.key}']",
             "Testing"
           )

    view |> element("#edit-column-#{column.id}") |> render_click()
    view |> form("#column-form", column: %{title: "Quality assurance"}) |> render_submit()

    assert has_element?(other, "#heading-#{column.key}", "Quality assurance")

    assert has_element?(
             other,
             "#work-item-form select[name='work_item[status]'] option[value='#{column.key}']",
             "Quality assurance"
           )
  end

  test "removing an edited item's column preserves the draft and shows a conflict notice", %{
    conn: conn,
    board: board
  } do
    source = create_column(board, %{title: "Temporary stage"})
    destination = column_named(board, "To do")
    item = create_item(board, %{status: source.key})
    {:ok, view, _html} = live(conn, board_path(conn))
    view |> element("#edit-item-#{item.id}") |> render_click()

    view
    |> form("#work-item-form", work_item: %{title: "An unsaved draft"})
    |> render_change()

    {:ok, _deleted} = Boards.delete_column(board, source, destination.id)

    assert has_element?(view, "#editor-notice")
    assert has_element?(view, "#work-item-dialog")

    assert has_element?(
             view,
             "#work-item-form input[name='work_item[title]'][value='An unsaved draft']"
           )

    assert Boards.get_work_item(board, item.id).status == destination.key
    assert has_element?(view, "#items-#{destination.key} #work-item-#{item.id}")
    refute has_element?(view, "#column-#{source.key}")
  end

  defp open_settings(view) do
    view |> element("#configure-board") |> render_click()
  end

  defp create_column(board, attrs) do
    {:ok, column} = Boards.create_column(board, attrs)
    column
  end

  defp column_named(board, title) do
    Enum.find(Boards.list_columns(board), &(&1.title == title)) ||
      flunk("Expected a board column named #{inspect(title)}")
  end

  defp create_item(board, attrs \\ %{}) do
    {:ok, item} =
      Boards.create_work_item(
        board,
        Map.merge(
          %{title: "A work item", status: "backlog", type: :task, priority: :medium},
          attrs
        )
      )

    item
  end
end
