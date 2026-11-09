defmodule DevloomWeb.BoardLive do
  use DevloomWeb, :live_view

  alias Devloom.Boards
  alias Devloom.Boards.{Column, WorkItem}

  @empty_filters %{"q" => "", "type" => "", "priority" => "", "assignee" => ""}

  @impl true
  def mount(params, _session, socket) do
    board = Boards.get_workspace_board!(socket.assigns.current_scope)
    if connected?(socket), do: Boards.subscribe(socket.assigns.current_scope)

    socket =
      socket
      |> assign(
        page_title: "Team board",
        board: board,
        columns: [],
        settings_open?: false,
        editing_column: nil,
        column_form: nil,
        column_deleted?: false,
        deleting_column: nil,
        column_delete_form: to_form(%{"destination_id" => ""}, as: :column_delete),
        column_settings_notice: nil,
        active_view: if(params["view"] == "list", do: "list", else: "board"),
        filters: @empty_filters,
        filter_form: to_form(@empty_filters, as: :filters),
        item: nil,
        form: nil,
        editor_notice: nil,
        editor_deleted?: false,
        confirm_delete?: false,
        help_open?: params["help"] == "1"
      )

    {:ok, refresh_board(socket)}
  end

  @impl true
  def handle_event("new_item", params, socket) do
    columns = Boards.list_columns(socket.assigns.current_scope)
    column = Enum.find(columns, &(&1.key == params["status"])) || List.first(columns)
    item = %WorkItem{status: column.key}
    {:noreply, open_editor(socket, item)}
  end

  def handle_event("edit_item", %{"id" => id}, socket) do
    case Boards.get_work_item(socket.assigns.current_scope, id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This work item is no longer on the board.")
         |> refresh_board()}

      item ->
        {:noreply, open_editor(socket, item)}
    end
  end

  def handle_event("close_item", _params, socket) do
    {:noreply,
     assign(socket,
       item: nil,
       form: nil,
       confirm_delete?: false,
       editor_notice: nil,
       editor_deleted?: false
     )}
  end

  def handle_event("validate_item", %{"work_item" => attrs}, socket) do
    changeset =
      socket.assigns.item |> Boards.change_work_item(attrs) |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: item_form(changeset))}
  end

  def handle_event("save_item", %{"work_item" => attrs}, socket) do
    result =
      if socket.assigns.item.id do
        Boards.update_work_item(socket.assigns.current_scope, socket.assigns.item, attrs)
      else
        Boards.create_work_item(socket.assigns.current_scope, attrs)
      end

    case result do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(
           item: nil,
           form: nil,
           editor_notice: nil,
           editor_deleted?: false,
           confirm_delete?: false
         )
         |> put_flash(:info, "Work item saved. Your board is up to date.")
         |> refresh_board()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: item_form(changeset))}

      {:error, reason} ->
        {:noreply, editor_error(socket, reason)}
    end
  end

  def handle_event("delete_item", _params, socket) do
    {:noreply, assign(socket, confirm_delete?: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete?: false)}
  end

  def handle_event("confirm_delete", _params, socket) do
    case Boards.delete_work_item(socket.assigns.current_scope, socket.assigns.item) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(item: nil, form: nil, confirm_delete?: false)
         |> put_flash(:info, "Work item deleted.")
         |> refresh_board()}

      {:error, reason} ->
        {:noreply, socket |> assign(confirm_delete?: false) |> editor_error(reason)}
    end
  end

  def handle_event("reload_item", _params, socket) do
    case Boards.get_work_item(socket.assigns.current_scope, socket.assigns.item.id) do
      nil -> {:noreply, editor_error(socket, :not_found)}
      item -> {:noreply, open_editor(socket, item)}
    end
  end

  def handle_event("move_item", %{"id" => id, "status" => status} = params, socket) do
    case Boards.move_work_item(socket.assigns.current_scope, id, status, params["before_id"]) do
      {:ok, _item} ->
        {:reply, %{ok: true}, refresh_board(socket)}

      {:error, _reason} ->
        message = "This move could not be saved. The board has been refreshed; please try again."

        {:reply, %{ok: false, error: message},
         socket |> put_flash(:error, message) |> refresh_board()}
    end
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.merge(@empty_filters, Map.take(filters, Map.keys(@empty_filters)))

    {:noreply,
     socket
     |> assign(filters: filters, filter_form: to_form(filters, as: :filters))
     |> refresh_board()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(filters: @empty_filters, filter_form: to_form(@empty_filters, as: :filters))
     |> refresh_board()}
  end

  def handle_event("switch_view", %{"view" => view}, socket) when view in ["board", "list"] do
    {:noreply, assign(socket, active_view: view)}
  end

  def handle_event("seed_sample", _params, socket) do
    socket =
      case Boards.seed_sample_items(socket.assigns.current_scope) do
        {:ok, _items} ->
          socket

        {:error, :not_empty} ->
          put_flash(socket, :info, "Your board already has work items.")

        {:error, _reason} ->
          put_flash(socket, :error, "Example work items could not be added. Please try again.")
      end

    {:noreply, refresh_board(socket)}
  end

  def handle_event("show_help", _params, socket), do: {:noreply, assign(socket, help_open?: true)}

  def handle_event("close_help", _params, socket),
    do: {:noreply, assign(socket, help_open?: false)}

  def handle_event("configure_board", _params, socket) do
    {:noreply,
     socket
     |> assign(settings_open?: true, item: nil, form: nil, help_open?: false)
     |> new_column_form()
     |> refresh_board()}
  end

  def handle_event("close_column_settings", _params, socket) do
    {:noreply, assign(socket, settings_open?: false, deleting_column: nil)}
  end

  def handle_event("add_column", _params, socket) do
    {:noreply, socket |> new_column_form() |> refresh_settings()}
  end

  def handle_event("edit_column", %{"id" => id}, socket) do
    case Boards.get_column(socket.assigns.current_scope, id) do
      nil -> {:noreply, settings_error(socket, :not_found)}
      column -> {:noreply, socket |> edit_column_form(column) |> refresh_settings()}
    end
  end

  def handle_event("validate_column", %{"column" => attrs}, socket) do
    changeset =
      (socket.assigns.editing_column || %Column{})
      |> Boards.change_column(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, column_form: to_form(changeset, as: :column))}
  end

  def handle_event("save_column", %{"column" => attrs}, socket) do
    result =
      if socket.assigns.editing_column do
        Boards.update_column(socket.assigns.current_scope, socket.assigns.editing_column, attrs)
      else
        Boards.create_column(socket.assigns.current_scope, attrs)
      end

    case result do
      {:ok, _column} ->
        {:noreply, socket |> new_column_form() |> refresh_board()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, column_form: to_form(changeset, as: :column))}

      {:error, reason} ->
        {:noreply, settings_error(socket, reason)}
    end
  end

  def handle_event("move_column", %{"id" => id, "direction" => direction}, socket) do
    case Boards.move_column(socket.assigns.current_scope, id, direction) do
      {:ok, _column} -> {:noreply, refresh_board(socket)}
      {:error, reason} -> {:noreply, settings_error(socket, reason)}
    end
  end

  def handle_event("delete_column", %{"id" => id}, socket) do
    case Boards.get_column(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, settings_error(socket, :not_found)}

      column ->
        {:noreply,
         assign(socket,
           deleting_column: column,
           column_delete_form: to_form(%{"destination_id" => ""}, as: :column_delete),
           column_settings_notice: nil
         )}
    end
  end

  def handle_event("cancel_delete_column", _params, socket) do
    {:noreply, assign(socket, deleting_column: nil, column_settings_notice: nil)}
  end

  def handle_event("validate_column_delete", %{"column_delete" => params}, socket) do
    {:noreply, assign(socket, column_delete_form: to_form(params, as: :column_delete))}
  end

  def handle_event("confirm_delete_column", %{"column_delete" => params}, socket) do
    case Boards.delete_column(
           socket.assigns.current_scope,
           socket.assigns.deleting_column,
           params["destination_id"]
         ) do
      {:ok, _column} -> {:noreply, socket |> new_column_form() |> refresh_board()}
      {:error, reason} -> {:noreply, socket |> settings_error(reason) |> refresh_board()}
    end
  end

  def handle_event("reload_column", _params, socket) do
    case Boards.get_column(socket.assigns.current_scope, socket.assigns.editing_column.id) do
      nil -> {:noreply, settings_error(socket, :not_found)}
      column -> {:noreply, socket |> edit_column_form(column) |> refresh_settings()}
    end
  end

  @impl true
  def handle_info({:board_updated, board_id}, %{assigns: %{board: %{id: board_id}}} = socket) do
    socket = refresh_board(socket)

    socket =
      if socket.assigns.item && socket.assigns.item.id do
        case Boards.get_work_item(socket.assigns.current_scope, socket.assigns.item.id) do
          nil ->
            editor_error(socket, :not_found)

          item when item.lock_version != socket.assigns.item.lock_version ->
            editor_error(socket, :stale)

          _item ->
            socket
        end
      else
        socket
      end

    socket =
      if socket.assigns.editing_column do
        case Boards.get_column(socket.assigns.current_scope, socket.assigns.editing_column.id) do
          nil ->
            socket |> assign(column_deleted?: true) |> settings_error(:not_found)

          column when column.lock_version != socket.assigns.editing_column.lock_version ->
            settings_error(socket, :stale)

          _column ->
            socket
        end
      else
        socket
      end

    socket =
      if socket.assigns.deleting_column &&
           !Boards.get_column(socket.assigns.current_scope, socket.assigns.deleting_column.id) do
        socket |> assign(deleting_column: nil) |> settings_error(:not_found)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:workspace_access_changed, _workspace_id}, socket), do: {:noreply, socket}

  defp new_column_form(socket) do
    assign(socket,
      editing_column: nil,
      column_form: to_form(Boards.change_column(%Column{}), as: :column),
      column_deleted?: false,
      deleting_column: nil,
      column_settings_notice: nil
    )
  end

  defp edit_column_form(socket, column) do
    assign(socket,
      editing_column: column,
      column_form: to_form(Boards.change_column(column), as: :column),
      column_deleted?: false,
      deleting_column: nil,
      column_settings_notice: nil
    )
  end

  defp refresh_settings(socket) do
    stream(socket, :column_settings, socket.assigns.columns,
      reset: true,
      dom_id: &"column-setting-#{&1.id}"
    )
  end

  defp settings_error(socket, reason) do
    message =
      case reason do
        :last_column ->
          "Keep at least one column on your board. Add another column before deleting this one."

        :destination_required ->
          "Choose a destination for the work items before deleting this column."

        :invalid_destination ->
          "Choose another column on this board as the destination."

        :not_found ->
          "This column was removed in another session. Add a new column or select an existing one."

        :stale ->
          "This column changed in another session. Load the latest version before saving or deleting it."

        _ ->
          "The column could not be changed. Refresh the settings and try again."
      end

    assign(socket, column_settings_notice: message)
  end

  defp refresh_board(socket) do
    columns = Boards.list_columns(socket.assigns.current_scope)
    items = Boards.list_work_items(socket.assigns.current_scope)
    visible_items = Boards.list_work_items(socket.assigns.current_scope, socket.assigns.filters)
    counts = Enum.frequencies_by(visible_items, & &1.status)
    completed_keys = for column <- columns, column.completed, do: column.key
    done_count = Enum.count(items, &(&1.status in completed_keys))
    total = length(items)

    socket =
      assign(socket,
        columns: columns,
        all_counts: Enum.frequencies_by(items, & &1.status),
        first_column_id: List.first(columns).id,
        last_column_id: List.last(columns).id,
        total_count: total,
        visible_count: length(visible_items),
        counts: counts,
        done_count: done_count,
        progress: if(total == 0, do: 0, else: round(done_count / total * 100)),
        filtered?:
          Enum.any?(socket.assigns.filters, fn {_key, value} -> value not in [nil, "", "all"] end)
      )

    socket =
      socket
      |> stream(:board_columns, columns, reset: true, dom_id: &"column-#{&1.key}")
      |> stream(:column_settings, columns, reset: true, dom_id: &"column-setting-#{&1.id}")

    Enum.reduce(columns, socket, fn column, socket ->
      stream(socket, column.key, Enum.filter(visible_items, &(&1.status == column.key)),
        reset: true,
        dom_id: &"work-item-#{&1.id}"
      )
    end)
  end

  defp open_editor(socket, item) do
    assign(socket,
      settings_open?: false,
      help_open?: false,
      item: item,
      form: item_form(Boards.change_work_item(item)),
      editor_notice: nil,
      editor_deleted?: false,
      confirm_delete?: false
    )
  end

  defp item_form(changeset) do
    to_form(changeset, as: :work_item)
  end

  defp editor_error(socket, :not_found) do
    assign(socket,
      editor_notice:
        "This work item was deleted in another session. Your unsaved text is still here to copy.",
      editor_deleted?: true
    )
  end

  defp editor_error(socket, _reason) do
    assign(socket,
      editor_notice:
        "This work item changed in another session. Copy your changes, then load the latest version before saving."
    )
  end

  defp labels_value(form) do
    case form[:labels].value do
      labels when is_list(labels) -> Enum.join(labels, ", ")
      value -> value
    end
  end

  defp type_icon(:feature), do: "hero-sparkles"
  defp type_icon(:bug), do: "hero-bug-ant"
  defp type_icon(_type), do: "hero-check-circle"
  defp type_label(:feature), do: "Feature"
  defp type_label(:bug), do: "Bug"
  defp type_label(_type), do: "Task"
  defp priority_icon(:urgent), do: "hero-exclamation-circle"
  defp priority_icon(:high), do: "hero-chevron-double-up"
  defp priority_icon(:medium), do: "hero-bars-2"
  defp priority_icon(_priority), do: "hero-chevron-down"
  defp priority_label(priority), do: priority |> to_string() |> String.capitalize()

  defp initials(name),
    do:
      name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view={@active_view}>
      <section class="board-page" aria-labelledby="board-title">
        <header class="page-heading">
          <div>
            <div class="page-eyebrow"><span class="eyebrow-line"></span>DEVELOPMENT TEAM</div>
            <div class="page-title-row">
              <h1 id="board-title">Team board</h1><span class="shared-badge"><.icon
                name="hero-user-group"
                class="size-3"
              /> Shared</span>
            </div>
            <p class="page-intro">Big ideas. Small steps. A clear path to done.</p>
          </div>
          <div class="heading-actions">
            <button
              id="configure-board"
              class="button button-secondary configure-button"
              phx-click="configure_board"
              aria-label="Configure board columns"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4" /><span>Configure board</span>
            </button>
            <button
              id="show-board-guide"
              class="button button-secondary guide-button"
              phx-click="show_help"
            ><.icon name="hero-question-mark-circle" class="size-4" />Board guide</button>
            <button id="new-work-item" class="button button-primary" phx-click="new_item"><.icon
              name="hero-plus"
              class="size-[18px]"
            />New work item</button>
          </div>
        </header>

        <div class="board-tabs-row">
          <nav class="board-tabs" aria-label="Work item views">
            <button
              id="view-board"
              phx-click="switch_view"
              phx-value-view="board"
              class={["board-tab", @active_view == "board" && "selected"]}
              aria-pressed={@active_view == "board"}
            ><.icon name="hero-view-columns" class="size-4" />Board</button>
            <button
              id="view-list"
              phx-click="switch_view"
              phx-value-view="list"
              class={["board-tab", @active_view == "list" && "selected"]}
              aria-pressed={@active_view == "list"}
            ><.icon name="hero-list-bullet" class="size-4" />Work items<span
              id="total-items"
              data-count={@total_count}
              class="tab-count"
            >{@total_count}</span></button>
          </nav>
          <span class="board-autosave"><.icon name="hero-cloud" class="size-4" />
          Changes saved automatically</span>
        </div>

        <div class="board-controls">
          <.form
            for={@filter_form}
            id="board-filters"
            phx-change="filter"
            phx-submit="filter"
            class="board-filters"
          >
            <div class="search-field">
              <.icon name="hero-magnifying-glass" class="size-4" /><.input
                field={@filter_form[:q]}
                id="board-search"
                type="search"
                placeholder="Search work items…"
                class="search-input"
                phx-debounce="200"
                aria-label="Search work items"
              /><kbd>/</kbd>
            </div>
            <div class="filter-fields">
              <.input
                field={@filter_form[:type]}
                type="select"
                class="filter-select"
                aria-label="Filter by work item type"
                options={[{"All types", ""}, {"Feature", "feature"}, {"Task", "task"}, {"Bug", "bug"}]}
              />
              <.input
                field={@filter_form[:priority]}
                type="select"
                class="filter-select"
                aria-label="Filter by priority"
                options={[
                  {"All priorities", ""},
                  {"Urgent", "urgent"},
                  {"High", "high"},
                  {"Medium", "medium"},
                  {"Low", "low"}
                ]}
              />
              <.input
                field={@filter_form[:assignee]}
                type="select"
                class="filter-select assignee-filter"
                aria-label="Filter by assignee"
                options={[{"All assignees", ""}, {"Unassigned", "unassigned"}]}
              />
            </div>
          </.form>
          <button :if={@filtered?} id="clear-filters" class="clear-filters" phx-click="clear_filters"><.icon
            name="hero-x-mark"
            class="size-3"
          />Clear</button>
        </div>

        <div class="board-summary">
          <p>
            <span id="visible-items" data-count={@visible_count}>{@visible_count}</span> {if @filtered?,
              do: "matching work items",
              else: "work items"}<span class="summary-dot">·</span><span class="summary-team">One team. One shared view.</span>
          </p>
          <div class="completion-summary">
            <span
              class="completion-track"
              role="progressbar"
              aria-label="Completed work items"
              aria-valuemin="0"
              aria-valuemax="100"
              aria-valuenow={@progress}
            ><span style={"width: #{@progress}%"}></span></span><span><strong
              id="completed-items"
              data-count={@done_count}
            >{@done_count}</strong>
            of {@total_count} done</span>
          </div>
        </div>

        <div :if={@total_count == 0} id="empty-board" class="empty-board">
          <span class="empty-board-icon"><.icon name="hero-view-columns" class="size-7" /></span>
          <div>
            <h2>Your next great thing starts here.</h2><p>
              Add your first work item, or explore with a few example tasks.
            </p>
          </div>
          <button
            id="load-sample-items"
            class="button button-secondary"
            phx-click="seed_sample"
            phx-disable-with="Adding examples…"
          ><.icon name="hero-sparkles" class="size-4" />Try an example board</button>
        </div>

        <div
          class="board-scroll"
          tabindex="0"
          role="region"
          aria-label="Kanban workflow. Scroll horizontally to see all columns."
        >
          <div
            id="kanban-board"
            phx-hook="KanbanBoard"
            phx-update="stream"
            class="kanban-board"
            data-view={@active_view}
            style={"--column-count: #{length(@columns)}"}
          >
            <section
              :for={{column_dom_id, column} <- @streams.board_columns}
              id={column_dom_id}
              class="kanban-column"
              data-status={column.key}
              data-color={column.color}
              data-completed={to_string(column.completed)}
              aria-labelledby={"heading-#{column.key}"}
            >
              <header class="column-heading">
                <div class="column-title">
                  <span class="column-status-dot"></span><h2
                    id={"heading-#{column.key}"}
                    data-column-title
                  >
                    {column.title}
                  </h2><span
                    id={"count-#{column.key}"}
                    class="column-count"
                    data-count={Map.get(@counts, column.key, 0)}
                  >{Map.get(@counts, column.key, 0)}</span><button
                    id={"add-item-#{column.key}"}
                    class="icon-button column-add"
                    phx-click="new_item"
                    phx-value-status={column.key}
                    aria-label={"Add work item to #{column.title}"}
                  ><.icon name="hero-plus" class="size-4" /></button>
                </div>
                <p :if={column.description != ""}>{column.description}</p>
              </header>
              <div id={"items-#{column.key}"} phx-update="stream" class="column-items">
                <div id={"empty-#{column.key}"} class="column-empty hidden only:flex">
                  <span class="empty-column-icon"><.icon
                    name={if column.completed, do: "hero-check-circle", else: "hero-inbox"}
                    class="size-5"
                  /></span><span>{if @filtered?,
                    do: "No matching items",
                    else: "A little room for what's next"}</span><span class="empty-column-hint">{if @filtered?,
                    do: "Try adjusting your filters",
                    else: "Drop a work item here"}</span>
                </div>
                <article
                  :for={{dom_id, item} <- @streams[column.key]}
                  id={dom_id}
                  class="work-card"
                  data-work-item-id={item.id}
                  data-type={item.type}
                  draggable="true"
                >
                  <div class="card-topline">
                    <span class="work-type"><.icon name={type_icon(item.type)} class="size-3.5" />{type_label(
                      item.type
                    )}</span><span class="work-id">DV-{item.id}</span><button
                      type="button"
                      class="drag-handle"
                      data-drag-handle
                      aria-label={"Move DV-#{item.id}: #{item.title}"}
                      title="Drag to move · Space to move with keyboard"
                    ><.icon name="hero-ellipsis-horizontal" class="size-[18px]" /></button>
                  </div>
                  <button
                    id={"edit-item-#{item.id}"}
                    class="card-title"
                    data-card-title
                    phx-click="edit_item"
                    phx-value-id={item.id}
                  >{item.title}</button>
                  <p :if={item.description && item.description != ""} class="card-description">
                    {item.description}
                  </p>
                  <div :if={item.labels != []} class="card-labels">
                    <span :for={label <- item.labels} class="card-label">{label}</span>
                  </div>
                  <footer class="card-footer">
                    <span class="card-assignee" title={item.assignee || "Unassigned"}><span class={[
                      "assignee-avatar",
                      is_nil(item.assignee) && "unassigned"
                    ]}><%= if item.assignee do %>
                      {initials(item.assignee)}
                    <% else %>
                      <.icon name="hero-user" class="size-3" />
                    <% end %></span><span>{item.assignee || "Unassigned"}</span></span><span
                      class="card-priority"
                      data-priority={item.priority}
                      title={"#{priority_label(item.priority)} priority"}
                    ><.icon name={priority_icon(item.priority)} class="size-3.5" /><span>{priority_label(
                      item.priority
                    )}</span></span><span
                      :if={!is_nil(item.estimate)}
                      class="card-estimate"
                      title={"#{item.estimate} story points"}
                    >{item.estimate}</span>
                  </footer>
                </article>
              </div>
              <button
                id={"quick-add-#{column.key}"}
                class="column-new-item"
                phx-click="new_item"
                phx-value-status={column.key}
              ><.icon name="hero-plus" class="size-4" />New work item</button>
            </section>
          </div>
        </div>
        <footer class="board-footer">
          <span><.icon name="hero-arrows-pointing-out" class="size-3.5" />Drag cards to move work forward<span class="footer-keyboard"> · Or use the card's move button and your keyboard</span></span><span class="board-footer-brand"><span class="footer-status-dot"></span>Built for your flow.</span>
        </footer>
        <p
          id="board-announcer"
          class="sr-only"
          role="status"
          aria-live="polite"
          aria-atomic="true"
          phx-update="ignore"
        >
        </p>
      </section>

      <div :if={@item} class="dialog-layer">
        <button
          class="dialog-backdrop"
          phx-click="close_item"
          aria-label="Close work item panel"
          tabindex="-1"
        ></button>
        <section
          id="work-item-dialog"
          class="item-drawer"
          role="dialog"
          aria-modal="true"
          aria-labelledby="editor-heading"
          phx-hook="FocusDialog"
          phx-window-keydown="close_item"
          phx-key="Escape"
        >
          <header class="drawer-header">
            <div>
              <span class="drawer-eyebrow">{if @item.id,
                do: "DV-#{@item.id}",
                else: "DEVLOOM / WORK ITEMS"}</span><h2 id="editor-heading">
                {if @item.id, do: "Work item details", else: "New work item"}
              </h2>
            </div><button
              id="close-work-item"
              class="icon-button"
              phx-click="close_item"
              aria-label="Close work item"
            ><.icon name="hero-x-mark" class="size-5" /></button>
          </header>
          <.form
            for={@form}
            id="work-item-form"
            class="work-item-form"
            phx-change="validate_item"
            phx-submit="save_item"
          >
            <div class="drawer-body">
              <div :if={@editor_notice} id="editor-notice" class="editor-notice" role="alert">
                <.icon name="hero-exclamation-triangle" class="size-5" /><div>
                  <p>{@editor_notice}</p><button
                    :if={!@editor_deleted?}
                    id="reload-work-item"
                    type="button"
                    phx-click="reload_item"
                  >Load latest version</button>
                </div>
              </div>
              <.input
                field={@form[:title]}
                label="Title"
                class="form-input title-input"
                placeholder="What needs to be done?"
                maxlength="180"
                required
                data-autofocus
              />
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description"
                class="form-input description-input"
                placeholder="Add the details, context, and a definition of done…"
                rows="6"
                maxlength="10000"
              />
              <div class="form-section-label">
                <.icon name="hero-adjustments-horizontal" class="size-4" />DETAILS
              </div>
              <div class="form-grid">
                <.input
                  field={@form[:type]}
                  type="select"
                  label="Work item type"
                  class="form-input"
                  options={[{"Feature", "feature"}, {"Task", "task"}, {"Bug", "bug"}]}
                />
                <.input
                  field={@form[:status]}
                  type="select"
                  label="Status"
                  class="form-input"
                  options={Enum.map(@columns, &{&1.title, &1.key})}
                />
                <.input
                  field={@form[:priority]}
                  type="select"
                  label="Priority"
                  class="form-input"
                  options={[
                    {"Low", "low"},
                    {"Medium", "medium"},
                    {"High", "high"},
                    {"Urgent", "urgent"}
                  ]}
                />
                <.input
                  field={@form[:estimate]}
                  type="number"
                  label="Story points"
                  class="form-input"
                  min="0"
                  max="100"
                  placeholder="Not estimated"
                />
              </div>
              <.input
                field={@form[:assignee]}
                label="Assignee"
                class="form-input"
                maxlength="100"
                placeholder="Unassigned — enter a name"
              />
              <p class="field-hint">Use a name for now. Team accounts will connect here later.</p>
              <.input
                field={@form[:labels]}
                value={labels_value(@form)}
                label="Labels"
                class="form-input"
                placeholder="e.g. Frontend, Design"
              />
              <p class="field-hint">Separate labels with commas.</p>
              <div :if={@confirm_delete?} id="delete-confirmation" class="delete-confirmation">
                <strong>Delete this work item?</strong><p>
                  This removes it from the shared board for everyone.
                </p><div>
                  <button
                    id="cancel-delete-work-item"
                    type="button"
                    class="button button-secondary"
                    phx-click="cancel_delete"
                  >Keep work item</button><button
                    id="confirm-delete-work-item"
                    type="button"
                    class="button button-danger"
                    phx-click="confirm_delete"
                    phx-disable-with="Deleting…"
                  >Yes, delete item</button>
                </div>
              </div>
            </div>
            <footer class="drawer-footer">
              <button
                :if={@item.id && !@editor_deleted?}
                id="delete-work-item"
                type="button"
                class="button button-delete"
                phx-click="delete_item"
              ><.icon name="hero-trash" class="size-4" />Delete</button><div class="drawer-save-actions">
                <button type="button" class="button button-secondary" phx-click="close_item">Cancel</button><button
                  id="save-work-item"
                  type="submit"
                  class="button button-primary"
                  phx-disable-with="Saving…"
                  disabled={@editor_deleted?}
                ><.icon name="hero-check" class="size-4" />{if @item.id,
                  do: "Save changes",
                  else: "Create work item"}</button>
              </div>
            </footer>
          </.form>
        </section>
      </div>

      <div :if={@settings_open?} class="dialog-layer">
        <button
          class="dialog-backdrop"
          phx-click="close_column_settings"
          aria-label="Close board configuration"
          tabindex="-1"
        ></button>
        <section
          id="column-settings-dialog"
          class="item-drawer column-settings-drawer"
          role="dialog"
          aria-modal="true"
          aria-labelledby="column-settings-heading"
          phx-hook="FocusDialog"
          phx-window-keydown="close_column_settings"
          phx-key="Escape"
        >
          <header class="drawer-header">
            <div>
              <span class="drawer-eyebrow">YOUR TEAM. YOUR WORKFLOW.</span><h2 id="column-settings-heading">
                Configure your board
              </h2>
            </div>
            <button
              id="close-column-settings"
              class="icon-button"
              phx-click="close_column_settings"
              aria-label="Close column settings"
              data-autofocus
            ><.icon name="hero-x-mark" class="size-5" /></button>
          </header>
          <div class="column-settings-body">
            <p class="settings-intro">
              Shape the workflow around the way your team works. Column changes are saved for everyone, in real time.
            </p>
            <div
              :if={@column_settings_notice}
              id="column-settings-notice"
              class="editor-notice"
              role="alert"
            >
              <.icon name="hero-exclamation-triangle" class="size-5" /><div>
                <p>{@column_settings_notice}</p><button
                  :if={@editing_column && !@column_deleted?}
                  id="reload-column"
                  phx-click="reload_column"
                >Load latest version</button>
              </div>
            </div>
            <div class="settings-section-heading">
              <div>
                <h3>Workflow columns</h3><span>{length(@columns)} columns · ordered from left to right</span>
              </div><button
                id="add-board-column"
                class="button button-secondary"
                phx-click={JS.push("add_column") |> JS.focus(to: "#column_title")}
              ><.icon name="hero-plus" class="size-4" />Add column</button>
            </div>
            <div id="column-settings-list" phx-update="stream" class="column-settings-list">
              <div
                :for={{dom_id, column} <- @streams.column_settings}
                id={dom_id}
                class={[
                  "column-setting-row",
                  @editing_column && @editing_column.id == column.id && "is-editing"
                ]}
                data-color={column.color}
              >
                <span class="column-status-dot"></span>
                <button
                  id={"edit-column-#{column.id}"}
                  class="column-setting-title"
                  phx-click={JS.push("edit_column") |> JS.focus(to: "#column_title")}
                  phx-value-id={column.id}
                ><span>{column.title}<.icon
                  :if={column.completed}
                  name="hero-check-circle"
                  class="size-3"
                /></span><small>{Map.get(@all_counts, column.key, 0)} {if Map.get(
                                                                            @all_counts,
                                                                            column.key,
                                                                            0
                                                                          ) == 1,
                                                                          do: "work item",
                                                                          else: "work items"}</small></button>
                <div class="column-setting-actions">
                  <button
                    id={"move-column-left-#{column.id}"}
                    class="icon-button"
                    phx-click="move_column"
                    phx-value-id={column.id}
                    phx-value-direction="left"
                    disabled={column.id == @first_column_id}
                    aria-label={"Move #{column.title} earlier"}
                    title="Move earlier"
                  ><.icon name="hero-chevron-up" class="size-3.5" /></button>
                  <button
                    id={"move-column-right-#{column.id}"}
                    class="icon-button"
                    phx-click="move_column"
                    phx-value-id={column.id}
                    phx-value-direction="right"
                    disabled={column.id == @last_column_id}
                    aria-label={"Move #{column.title} later"}
                    title="Move later"
                  ><.icon name="hero-chevron-down" class="size-3.5" /></button>
                  <button
                    id={"delete-column-#{column.id}"}
                    class="icon-button column-delete-button"
                    phx-click="delete_column"
                    phx-value-id={column.id}
                    disabled={length(@columns) == 1}
                    aria-label={"Delete #{column.title} column"}
                    title={
                      if length(@columns) == 1, do: "Keep at least one column", else: "Delete column"
                    }
                  ><.icon name="hero-trash" class="size-3.5" /></button>
                </div>
              </div>
            </div>
            <p :if={length(@columns) == 1} class="settings-minimum-note">
              Your board needs at least one column.
            </p>

            <div
              :if={@deleting_column}
              id="column-delete-confirmation"
              class="column-delete-confirmation"
              phx-mounted={JS.focus(to: "#column_delete_destination_id")}
            >
              <div class="delete-column-heading">
                <.icon name="hero-trash" class="size-4" /><h3>Delete “{@deleting_column.title}”?</h3>
              </div>
              <p>
                <%= if Map.get(@all_counts, @deleting_column.key, 0) > 0 do %>
                  This column contains {Map.get(@all_counts, @deleting_column.key, 0)} work items. Choose where to move them. They will be added to the end of that column.
                <% else %>
                  This column is empty. Deleting it leaves your work items unchanged.
                <% end %>
              </p>
              <.form
                for={@column_delete_form}
                id="column-delete-form"
                phx-change="validate_column_delete"
                phx-submit="confirm_delete_column"
              >
                <.input
                  field={@column_delete_form[:destination_id]}
                  type="select"
                  label="Move work items to"
                  class="form-input"
                  options={
                    [{"Choose a destination…", ""}] ++
                      for column <- @columns,
                          column.id != @deleting_column.id,
                          do: {column.title, column.id}
                  }
                />
                <div class="delete-column-actions">
                  <button
                    id="cancel-delete-column"
                    type="button"
                    class="button button-secondary"
                    phx-click="cancel_delete_column"
                  >Keep column</button><button
                    id="confirm-delete-column"
                    type="submit"
                    class="button button-danger"
                    phx-disable-with="Deleting…"
                    disabled={
                      length(@columns) == 1 ||
                        (Map.get(@all_counts, @deleting_column.key, 0) > 0 &&
                           @column_delete_form[:destination_id].value in [nil, ""])
                    }
                  >Delete column</button>
                </div>
              </.form>
            </div>

            <div class="column-form-heading">
              <div>
                <h3>{if @editing_column, do: "Edit column", else: "Add a column"}</h3><p>
                  {if @editing_column,
                    do: "Update the details without moving any work items.",
                    else: "Make room for the next step in your workflow."}
                </p>
              </div>
            </div>
            <.form
              for={@column_form}
              id="column-form"
              class="column-form"
              phx-change="validate_column"
              phx-submit="save_column"
            >
              <.input
                field={@column_form[:title]}
                label="Column name"
                class="form-input"
                placeholder="e.g. Quality assurance"
                maxlength="40"
                required
              />
              <.input
                field={@column_form[:description]}
                label="Short description"
                class="form-input"
                placeholder="e.g. One final check before shipping"
                maxlength="100"
              />
              <.input
                field={@column_form[:color]}
                type="select"
                label="Column color"
                class="form-input"
                options={[
                  {"Blue", "blue"},
                  {"Gray", "neutral"},
                  {"Amber", "amber"},
                  {"Purple", "purple"},
                  {"Green", "green"},
                  {"Rose", "rose"}
                ]}
              />
              <.input
                field={@column_form[:completed]}
                type="checkbox"
                label="Work in this column counts as complete"
                class="column-completed-checkbox"
              />
              <p class="field-hint completed-hint">
                Completed columns contribute to the board's progress indicator.
              </p>
              <div class="column-form-footer">
                <button
                  id="save-board-column"
                  type="submit"
                  class="button button-primary"
                  phx-disable-with="Saving…"
                  disabled={@column_deleted?}
                ><.icon name={if @editing_column, do: "hero-check", else: "hero-plus"} class="size-4" />{if @editing_column,
                  do: "Save column",
                  else: "Add column"}</button>
              </div>
            </.form>
          </div>
          <footer class="column-settings-footer">
            <.icon name="hero-cloud" class="size-4" /><span>Changes are shared with everyone on this board.</span><button
              id="done-column-settings"
              class="button button-secondary"
              phx-click="close_column_settings"
            >Done</button>
          </footer>
        </section>
      </div>

      <div :if={@help_open?} class="dialog-layer help-layer">
        <button
          class="dialog-backdrop"
          phx-click="close_help"
          aria-label="Close board guide"
          tabindex="-1"
        ></button>
        <section
          id="board-guide"
          class="help-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="help-heading"
          phx-hook="FocusDialog"
          phx-window-keydown="close_help"
          phx-key="Escape"
        >
          <header class="drawer-header">
            <div>
              <span class="drawer-eyebrow">A PLACE TO KEEP WORK MOVING</span><h2 id="help-heading">
                Make the board your own.
              </h2>
            </div><button
              id="close-board-guide"
              class="icon-button"
              phx-click="close_help"
              aria-label="Close board guide"
            ><.icon name="hero-x-mark" class="size-5" /></button>
          </header>
          <div class="help-body">
            <p>
              Create a work item, give it some context, and move it through the workflow. Everyone with this board open sees changes as they happen.
            </p><div class="help-feature">
              <.icon name="hero-cursor-arrow-rays" class="size-5" /><div>
                <strong>Move work your way</strong><p>
                  Drag a card between columns or reorder it within a column. On touch screens, drag its three-dot move handle.
                </p>
              </div>
            </div><div class="help-feature">
              <.icon name="hero-pencil-square" class="size-5" /><div>
                <strong>The details are one click away</strong><p>
                  Click any card title to edit its description, priority, labels, estimate, and assignee. Change its status here for another way to move it.
                </p>
              </div>
            </div><div class="keyboard-guide">
              <h3>KEYBOARD SHORTCUTS</h3><div><span>Find a work item</span><kbd>/</kbd></div><div>
                <span>Pick up / drop a focused move handle</span><kbd>Space</kbd>
              </div><div>
                <span>Choose a column or position</span><span><kbd>←</kbd> <kbd>↑</kbd> <kbd>↓</kbd>
                <kbd>→</kbd></span>
              </div><div><span>Cancel a move or close a panel</span><kbd>Esc</kbd></div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
