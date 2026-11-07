defmodule Devloom.Boards do
  @moduledoc """
  Persistent Kanban work, scoped to a board.

  Board row locks serialize edits and reorders so concurrent sessions cannot
  corrupt a column's ordering. Notifications are published after commit.
  Authentication can later resolve a member's board before calling this context.
  """
  import Ecto.Query

  alias Devloom.Boards.{Board, Column, WorkItem}
  alias Devloom.Repo

  def get_default_board! do
    {:ok, board} =
      Repo.transaction(fn ->
        board =
          Repo.insert!(%Board{name: "Devloom", slug: "development"},
            on_conflict: :nothing,
            conflict_target: :slug
          )

        if board.id do
          Enum.each(default_columns(), fn attrs ->
            Repo.insert!(struct!(Column, Map.put(attrs, :board_id, board.id)))
          end)

          board
        else
          Repo.get_by!(Board, slug: "development")
        end
      end)

    board
  end

  def list_columns(%Board{id: board_id}) do
    Repo.all(
      from column in Column,
        where: column.board_id == ^board_id,
        order_by: [asc: column.position, asc: column.id]
    )
  end

  def get_column(%Board{id: board_id}, id) do
    case cast_item_id(id) do
      {:ok, id} -> Repo.get_by(Column, id: id, board_id: board_id)
      _ -> nil
    end
  end

  def change_column(%Column{} = column, attrs \\ %{}), do: Column.changeset(column, attrs)

  def create_column(%Board{} = board, attrs) do
    mutate(board, fn ->
      %Column{
        board_id: board.id,
        key: "column_" <> String.replace(Ecto.UUID.generate(), "-", ""),
        position: length(list_columns(board))
      }
      |> Column.changeset(attrs)
      |> Repo.insert()
      |> unwrap!()
    end)
  end

  def update_column(%Board{} = board, %Column{} = column, attrs) do
    mutate(board, fn ->
      board
      |> current_column!(column)
      |> Column.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update()
      |> unwrap!()
    end)
  end

  def move_column(%Board{} = board, id, direction) do
    mutate(board, fn ->
      column = get_column(board, id) || Repo.rollback(:not_found)
      columns = list_columns(board)
      index = Enum.find_index(columns, &(&1.id == column.id))

      offset =
        case direction do
          "left" -> -1
          "right" -> 1
          _ -> Repo.rollback(:invalid_direction)
        end

      destination = index + offset

      if destination >= 0 and destination < length(columns) do
        other = Enum.at(columns, destination)

        columns
        |> List.replace_at(index, other)
        |> List.replace_at(destination, column)
        |> write_column_positions()
      end

      get_column(board, column.id)
    end)
  end

  @doc "Deletes a column, moving its cards to an explicitly chosen destination when necessary."
  def delete_column(%Board{} = board, %Column{} = column, destination_id \\ nil) do
    mutate(board, fn ->
      current = current_column!(board, column)
      columns = list_columns(board)
      if length(columns) == 1, do: Repo.rollback(:last_column)

      items = column_items(board, current.key)

      destination =
        cond do
          destination_id in [nil, ""] and items != [] ->
            Repo.rollback(:destination_required)

          destination_id in [nil, ""] ->
            nil

          true ->
            destination = get_column(board, destination_id)

            if !destination or destination.id == current.id do
              Repo.rollback(:invalid_destination)
            end

            destination
        end

      if items != [] do
        append_items_to_column(board, items, destination)
      end

      deleted = current |> Repo.delete() |> unwrap!()
      board |> list_columns() |> write_column_positions()
      deleted
    end)
  end

  def subscribe(%Board{id: id}) do
    Phoenix.PubSub.subscribe(Devloom.PubSub, topic(id))
  end

  def list_work_items(%Board{id: board_id}, filters \\ %{}) do
    WorkItem
    |> where([item], item.board_id == ^board_id)
    |> filter_query(filters)
    |> order_by([item], asc: item.position, asc: item.id)
    |> Repo.all()
  end

  def get_work_item(%Board{id: board_id}, id) do
    case cast_item_id(id) do
      {:ok, id} -> Repo.get_by(WorkItem, id: id, board_id: board_id)
      _ -> nil
    end
  end

  def change_work_item(%WorkItem{} = work_item, attrs \\ %{}) do
    WorkItem.changeset(work_item, attrs)
  end

  def create_work_item(%Board{} = board, attrs) do
    mutate(board, fn ->
      changeset =
        %WorkItem{board_id: board.id, status: first_column_key!(board)}
        |> WorkItem.changeset(attrs)
        |> validate_item_column(board)
        |> validate_changeset!(:insert)

      status = Ecto.Changeset.get_field(changeset, :status)

      changeset
      |> Ecto.Changeset.put_change(:position, next_position(board, status))
      |> Repo.insert()
      |> unwrap!()
    end)
  end

  def update_work_item(%Board{} = board, %WorkItem{} = work_item, attrs) do
    mutate(board, fn ->
      current = current_item!(board, work_item)

      changeset =
        current
        |> WorkItem.changeset(attrs)
        |> validate_item_column(board)
        |> validate_changeset!(:update)

      status = Ecto.Changeset.get_field(changeset, :status)

      changeset =
        if status != current.status do
          Ecto.Changeset.put_change(changeset, :position, next_position(board, status))
        else
          changeset
        end

      updated =
        changeset
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
        |> unwrap!()

      compact_column(board, current.status)
      get_work_item(board, updated.id)
    end)
  end

  def delete_work_item(%Board{} = board, %WorkItem{} = work_item) do
    mutate(board, fn ->
      current = current_item!(board, work_item)
      deleted = current |> Repo.delete() |> unwrap!()
      compact_column(board, current.status)
      deleted
    end)
  end

  @doc "Moves an item before a destination item, or to the end when before_id is nil."
  def move_work_item(%Board{} = board, id, status, before_id \\ nil) do
    mutate(board, fn ->
      status = cast_status!(board, status)
      item = get_work_item(board, id) || Repo.rollback(:not_found)
      before_id = cast_before_id!(before_id)
      target = if before_id, do: get_work_item(board, before_id)

      if before_id && (!target || target.status != status) do
        Repo.rollback(:invalid_target)
      end

      if before_id == item.id do
        item
      else
        destination =
          column_items(board, status)
          |> Enum.reject(&(&1.id == item.id))

        {before, after_items} = Enum.split_while(destination, &(&1.id != before_id))
        reordered = before ++ [item] ++ after_items

        item
        |> Ecto.Changeset.change(status: status)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
        |> unwrap!()

        write_positions(reordered)

        if item.status != status, do: compact_column(board, item.status)

        get_work_item(board, item.id)
      end
    end)
  end

  @doc "Loads an example board only when it contains no work items."
  def seed_sample_items(%Board{} = board) do
    mutate(board, fn ->
      if Repo.exists?(from item in WorkItem, where: item.board_id == ^board.id) do
        Repo.rollback(:not_empty)
      end

      columns = list_columns(board)
      first = List.first(columns) || Repo.rollback(:invalid_status)
      keys = MapSet.new(columns, & &1.key)

      Enum.map(sample_items(), fn attrs ->
        status = to_string(attrs.status)
        status = if MapSet.member?(keys, status), do: status, else: first.key
        attrs = Map.put(attrs, :status, status)

        %WorkItem{board_id: board.id}
        |> WorkItem.changeset(attrs)
        |> Ecto.Changeset.put_change(:position, next_position(board, status))
        |> Repo.insert!()
      end)
    end)
  end

  defp mutate(board, fun) do
    result =
      Repo.transaction(fn ->
        Repo.one(from current in Board, where: current.id == ^board.id, lock: "FOR UPDATE") ||
          Repo.rollback(:not_found)

        fun.()
      end)

    case result do
      {:ok, value} ->
        Phoenix.PubSub.broadcast(Devloom.PubSub, topic(board.id), {:board_updated, board.id})
        {:ok, value}

      error ->
        error
    end
  end

  defp current_item!(board, item) do
    current = get_work_item(board, item.id) || Repo.rollback(:not_found)

    if item.board_id != board.id, do: Repo.rollback(:not_found)
    if item.lock_version != current.lock_version, do: Repo.rollback(:stale)

    current
  end

  defp current_column!(board, column) do
    current = get_column(board, column.id) || Repo.rollback(:not_found)

    if column.board_id != board.id, do: Repo.rollback(:not_found)
    if column.lock_version != current.lock_version, do: Repo.rollback(:stale)

    current
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp validate_changeset!(%Ecto.Changeset{valid?: true} = changeset, _action), do: changeset

  defp validate_changeset!(changeset, action) do
    Repo.rollback(%{changeset | action: action})
  end

  defp cast_status!(board, status) do
    status = if is_atom(status) and not is_nil(status), do: Atom.to_string(status), else: status

    if is_binary(status) and
         Repo.exists?(
           from column in Column, where: column.board_id == ^board.id and column.key == ^status
         ) do
      status
    else
      Repo.rollback(:invalid_status)
    end
  end

  defp first_column_key!(board) do
    case list_columns(board) do
      [column | _] -> column.key
      [] -> Repo.rollback(:invalid_status)
    end
  end

  defp validate_item_column(changeset, board) do
    status = Ecto.Changeset.get_field(changeset, :status)

    if is_binary(status) and
         Repo.exists?(
           from column in Column, where: column.board_id == ^board.id and column.key == ^status
         ) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :status, "select an available column")
    end
  end

  defp append_items_to_column(board, items, destination) do
    start = next_position(board, destination.key)
    now = DateTime.utc_now(:second)

    items
    |> Enum.with_index(start)
    |> Enum.each(fn {item, position} ->
      Repo.update_all(
        from(current in WorkItem,
          where: current.id == ^item.id and current.board_id == ^board.id
        ),
        set: [status: destination.key, position: position, updated_at: now],
        inc: [lock_version: 1]
      )
    end)
  end

  defp write_column_positions(columns) do
    now = DateTime.utc_now(:second)

    columns
    |> Enum.with_index()
    |> Enum.each(fn {column, position} ->
      if column.position != position do
        Repo.update_all(from(current in Column, where: current.id == ^column.id),
          set: [position: position, updated_at: now],
          inc: [lock_version: 1]
        )
      end
    end)
  end

  defp cast_before_id!(id) when id in [nil, ""], do: nil

  defp cast_before_id!(id) do
    case cast_item_id(id) do
      {:ok, id} -> id
      _ -> Repo.rollback(:invalid_target)
    end
  end

  defp cast_item_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> :error
    end
  end

  defp next_position(board, status) do
    Repo.one(
      from item in WorkItem,
        where: item.board_id == ^board.id and item.status == ^status,
        select: max(item.position)
    )
    |> case do
      nil -> 0
      position -> position + 1
    end
  end

  defp column_items(board, status) do
    Repo.all(
      from item in WorkItem,
        where: item.board_id == ^board.id and item.status == ^status,
        order_by: [asc: item.position, asc: item.id]
    )
  end

  defp compact_column(board, status), do: board |> column_items(status) |> write_positions()

  defp write_positions(items) do
    items
    |> Enum.with_index()
    |> Enum.each(fn {item, position} ->
      if item.position != position do
        Repo.update_all(from(current in WorkItem, where: current.id == ^item.id),
          set: [position: position]
        )
      end
    end)
  end

  defp filter_query(query, filters) do
    query =
      Enum.reduce([{"type", :type}, {"priority", :priority}], query, fn {key, field}, query ->
        case Map.get(filters, key) do
          value when value in [nil, "", "all"] ->
            query

          value ->
            case Ecto.Enum.cast_value(WorkItem, field, value) do
              {:ok, value} -> where(query, [item], field(item, ^field) == ^value)
              :error -> where(query, false)
            end
        end
      end)

    query =
      case Map.get(filters, "q") do
        value when is_binary(value) and value != "" ->
          pattern = "%" <> escape_like(String.trim(value)) <> "%"
          where(query, [item], ilike(item.title, ^pattern) or ilike(item.description, ^pattern))

        _ ->
          query
      end

    if Map.get(filters, "assignee") == "unassigned" do
      where(query, [item], is_nil(item.assignee) or item.assignee == "")
    else
      query
    end
  end

  defp escape_like(value), do: String.replace(value, ["\\", "%", "_"], &"\\#{&1}")
  defp topic(id), do: "boards:#{id}"

  defp default_columns do
    [
      %{
        key: "backlog",
        title: "Backlog",
        description: "Ideas taking shape",
        color: :neutral,
        completed: false,
        position: 0
      },
      %{
        key: "todo",
        title: "To do",
        description: "Ready to get started",
        color: :blue,
        completed: false,
        position: 1
      },
      %{
        key: "in_progress",
        title: "In progress",
        description: "Good things in motion",
        color: :amber,
        completed: false,
        position: 2
      },
      %{
        key: "in_review",
        title: "In review",
        description: "A fresh pair of eyes",
        color: :purple,
        completed: false,
        position: 3
      },
      %{
        key: "done",
        title: "Done",
        description: "Built, checked, shipped",
        color: :green,
        completed: true,
        position: 4
      }
    ]
  end

  defp sample_items do
    [
      %{
        title: "Define workspace roles and permissions",
        description: "Map the owner, admin, and member permissions before adding authentication.",
        status: :backlog,
        type: :feature,
        priority: :high,
        labels: ["Planning", "Backend"],
        estimate: 5
      },
      %{
        title: "Explore a team documentation space",
        description:
          "Sketch a place for technical decisions, onboarding notes, and project knowledge.",
        status: :backlog,
        type: :feature,
        priority: :low,
        labels: ["Design"],
        estimate: 3
      },
      %{
        title: "Design the workspace invitation flow",
        description: "Plan invitations and membership for the next increment.",
        status: :todo,
        type: :feature,
        priority: :medium,
        labels: ["Design", "Frontend"],
        estimate: 3
      },
      %{
        title: "Document local development setup",
        description: "Keep the Docker setup and first-run steps clear for new contributors.",
        status: :todo,
        type: :task,
        priority: :medium,
        labels: ["Documentation"],
        estimate: 2
      },
      %{
        title: "Fix card layout on smaller screens",
        description: "Make long titles and labels fit cleanly without hiding the card controls.",
        status: :todo,
        type: :bug,
        priority: :high,
        labels: ["Frontend"],
        estimate: 2
      },
      %{
        title: "Build the team Kanban board",
        description:
          "Create the shared board with five workflow states and persistent work items.",
        status: :in_progress,
        type: :feature,
        priority: :high,
        labels: ["Frontend", "Backend"],
        estimate: 8
      },
      %{
        title: "Add live updates across sessions",
        description:
          "Publish committed board changes through Phoenix PubSub to connected sessions.",
        status: :in_progress,
        type: :task,
        priority: :high,
        labels: ["Backend"],
        estimate: 5
      },
      %{
        title: "Polish drag-and-drop interactions",
        description:
          "Support moving cards across columns and reordering them with clear drop feedback.",
        status: :in_progress,
        type: :task,
        priority: :medium,
        labels: ["Frontend"],
        estimate: 3
      },
      %{
        title: "Review the work item editor",
        description:
          "Check validation, keyboard navigation, and the create, edit, and delete flows.",
        status: :in_review,
        type: :task,
        priority: :medium,
        labels: ["Design", "Frontend"],
        estimate: 3
      },
      %{
        title: "Verify database health checks",
        description:
          "Return a useful health response when PostgreSQL is available or recovering.",
        status: :done,
        type: :task,
        priority: :medium,
        labels: ["Backend"],
        estimate: 2
      },
      %{
        title: "Set up the Phoenix application",
        description:
          "Establish the Phoenix, LiveView, PostgreSQL, and Docker development foundation.",
        status: :done,
        type: :feature,
        priority: :high,
        labels: ["Infrastructure"],
        estimate: 5
      },
      %{
        title: "Create the Devloom visual foundation",
        description:
          "Introduce the project shell, navigation, typography, and shared components.",
        status: :done,
        type: :task,
        priority: :low,
        labels: ["Design"],
        estimate: 3
      }
    ]
  end
end
