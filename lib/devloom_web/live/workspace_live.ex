defmodule DevloomWeb.WorkspaceLive do
  use DevloomWeb, :live_view

  alias Devloom.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    workspaces = Workspaces.list_workspaces(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: "Your workspaces",
       workspace_count: length(workspaces),
       deleting_workspace: nil,
       deletion_form: nil,
       form: to_form(Workspaces.change_workspace(), as: :workspace)
     )
     |> stream(:workspaces, workspaces, dom_id: &"workspace-#{&1.id}")}
  end

  @impl true
  def handle_event("validate_workspace", %{"workspace" => attrs}, socket) do
    form =
      attrs
      |> Workspaces.change_workspace()
      |> Map.put(:action, :validate)
      |> to_form(as: :workspace)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("create_workspace", %{"workspace" => attrs}, socket) do
    case Workspaces.create_workspace(socket.assigns.current_scope, attrs) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Your workspace is ready. Invite your team to get started.")
         |> push_navigate(to: ~p"/workspaces/#{workspace.id}/board")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :workspace))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Your workspace could not be created. Please try again.")}
    end
  end

  def handle_event("delete_workspace", %{"id" => id}, socket) do
    case fetch_deletable_scope(socket.assigns.current_scope, id) do
      {:ok, scope} ->
        {:noreply,
         assign(socket,
           deleting_workspace: scope.workspace,
           deletion_form: to_form(deletion_changeset(%{}, scope.workspace.name), as: :deletion)
         )}

      {:error, _reason} ->
        {:noreply, deletion_failed(socket)}
    end
  end

  def handle_event("cancel_delete_workspace", _params, socket) do
    {:noreply, assign(socket, deleting_workspace: nil, deletion_form: nil)}
  end

  def handle_event(
        "confirm_delete_workspace",
        _params,
        %{assigns: %{deleting_workspace: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("confirm_delete_workspace", %{"deletion" => attrs}, socket) do
    case fetch_deletable_scope(
           socket.assigns.current_scope,
           socket.assigns.deleting_workspace.id
         ) do
      {:ok, scope} ->
        changeset = deletion_changeset(attrs, scope.workspace.name)

        if changeset.valid? do
          case Workspaces.delete_workspace(scope) do
            {:ok, _workspace} ->
              {:noreply,
               socket
               |> assign(deleting_workspace: nil, deletion_form: nil)
               |> refresh_workspaces()
               |> put_flash(
                 :info,
                 "Workspace deleted. Its work items and chats have been permanently removed."
               )}

            {:error, _reason} ->
              {:noreply, deletion_failed(socket)}
          end
        else
          {:noreply,
           assign(socket,
             deleting_workspace: scope.workspace,
             deletion_form: to_form(Map.put(changeset, :action, :validate), as: :deletion)
           )}
        end

      {:error, _reason} ->
        {:noreply, deletion_failed(socket)}
    end
  end

  defp fetch_deletable_scope(scope, id) do
    with {:ok, workspace_scope} <- Workspaces.fetch_scope(scope, id),
         true <- Workspaces.can_delete_workspace?(workspace_scope) do
      {:ok, workspace_scope}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp deletion_changeset(attrs, workspace_name) do
    {%{}, %{name: :string}}
    |> Ecto.Changeset.cast(attrs, [:name])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_change(:name, fn :name, name ->
      if name == workspace_name, do: [], else: [name: "must match the workspace name exactly"]
    end)
  end

  defp deletion_failed(socket) do
    socket
    |> assign(deleting_workspace: nil, deletion_form: nil)
    |> refresh_workspaces()
    |> put_flash(
      :error,
      "This workspace could not be deleted. Only current owners and admins can delete an available workspace."
    )
  end

  defp refresh_workspaces(socket) do
    workspaces = Workspaces.list_workspaces(socket.assigns.current_scope)

    socket
    |> assign(workspace_count: length(workspaces))
    |> stream(:workspaces, workspaces, reset: true)
  end

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="workspaces">
      <section id="workspaces-page" class="workspaces-page" aria-labelledby="workspaces-title">
        <header class="page-heading workspace-page-heading">
          <div>
            <div class="page-eyebrow"><span class="eyebrow-line"></span>ROOM TO BUILD TOGETHER</div>
            <h1 id="workspaces-title">Your workspaces</h1>
            <p class="page-intro">A home for every team. The right context for every project.</p>
          </div>
          <span id="workspace-count" class="workspace-count"><.icon
            name="hero-squares-2x2"
            class="size-4"
          />{@workspace_count} {if @workspace_count ==
                                     1,
                                   do: "workspace",
                                   else: "workspaces"}</span>
        </header>

        <div class="workspace-overview-grid">
          <section class="workspace-directory" aria-label="Your workspace directory">
            <div :if={@workspace_count == 0} id="workspaces-empty" class="workspace-directory-empty">
              <span class="workspace-empty-icon"><.icon name="hero-building-office-2" class="size-7" /></span>
              <h2>Your next project starts here.</h2>
              <p>Create a workspace for your team, or open an invitation link to join one.</p>
              <span>Each workspace keeps its members, work, and conversations together.</span>
            </div>
            <div id="workspace-list" class="workspace-card-grid" phx-update="stream">
              <article
                :for={{dom_id, workspace} <- @streams.workspaces}
                id={dom_id}
                class="workspace-card"
              >
                <div class="workspace-card-topline">
                  <span class="workspace-card-avatar">{initials(workspace.name)}</span>
                  <div class="workspace-card-actions">
                    <span class={[
                      "workspace-role",
                      workspace.role == :owner && "is-owner",
                      workspace.role == :admin && "is-admin"
                    ]}>
                      {String.capitalize(to_string(workspace.role))}
                    </span>
                    <button
                      :if={workspace.role in [:owner, :admin]}
                      id={"delete-workspace-#{workspace.id}"}
                      type="button"
                      class="workspace-delete-button"
                      phx-click="delete_workspace"
                      phx-value-id={workspace.id}
                      aria-label={"Delete #{workspace.name}"}
                      aria-haspopup="dialog"
                    ><.icon name="hero-trash" class="size-3.5" />Delete</button>
                  </div>
                </div>
                <h2>
                  <.link navigate={~p"/workspaces/#{workspace.id}/board"}>{workspace.name}</.link>
                </h2>
                <p class="workspace-card-members">
                  <.icon name="hero-user-group" class="size-3.5" />{workspace.member_count} {if workspace.member_count ==
                                                                                                  1,
                                                                                                do:
                                                                                                  "member",
                                                                                                else:
                                                                                                  "members"}
                </p>
                <div class="workspace-card-links">
                  <.link
                    id={"open-workspace-#{workspace.id}"}
                    navigate={~p"/workspaces/#{workspace.id}/board"}
                  ><.icon name="hero-view-columns" class="size-3.5" />Board<.icon
                    name="hero-arrow-up-right"
                    class="size-3"
                  /></.link>
                  <.link navigate={~p"/workspaces/#{workspace.id}/chat"}><.icon
                    name="hero-chat-bubble-left-right"
                    class="size-3.5"
                  />Chat</.link>
                  <.link navigate={~p"/workspaces/#{workspace.id}/members"}><.icon
                    name="hero-users"
                    class="size-3.5"
                  />Members</.link>
                </div>
              </article>
            </div>
          </section>

          <aside class="workspace-create-panel" aria-labelledby="create-workspace-title">
            <span class="workspace-create-icon"><.icon name="hero-plus" class="size-5" /></span>
            <h2 id="create-workspace-title">Make space for your team.</h2>
            <p>
              Start a new workspace with its own board and team chat. You can invite members once it's ready.
            </p>
            <.form
              for={@form}
              id="workspace-create-form"
              class="workspace-form"
              phx-change="validate_workspace"
              phx-submit="create_workspace"
            >
              <.input
                field={@form[:name]}
                id="workspace-name"
                label="Workspace name"
                class="workspace-text-input"
                placeholder="e.g. Platform team"
                maxlength="80"
                required
                phx-debounce="300"
              />
              <button
                id="create-workspace"
                type="submit"
                class="button button-primary"
                phx-disable-with="Creating…"
              ><.icon name="hero-plus" class="size-4" />Create workspace</button>
            </.form>
            <div class="workspace-create-footnote">
              <.icon name="hero-lock-closed" class="size-3.5" /><span>Only members can access a workspace.</span>
            </div>
          </aside>
        </div>

        <div class="workspace-directory-note">
          <.icon name="hero-envelope-open" class="size-4" /><p>
            Joining an existing team? Ask a workspace owner for an invitation link.
          </p>
        </div>
      </section>

      <div :if={@deleting_workspace} class="dialog-layer workspace-delete-layer">
        <button
          id="dismiss-delete-workspace"
          type="button"
          class="dialog-backdrop"
          phx-click="cancel_delete_workspace"
          aria-label="Cancel workspace deletion"
          tabindex="-1"
        ></button>
        <section
          id="delete-workspace-confirmation"
          class="workspace-delete-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="delete-workspace-title"
          aria-describedby="delete-workspace-description"
          phx-hook="FocusDialog"
          phx-window-keydown="cancel_delete_workspace"
          phx-key="Escape"
        >
          <div class="workspace-delete-heading">
            <span class="workspace-delete-icon"><.icon name="hero-trash" class="size-6" /></span>
            <button
              id="close-delete-workspace"
              type="button"
              class="icon-button"
              phx-click="cancel_delete_workspace"
              aria-label="Cancel workspace deletion"
            ><.icon name="hero-x-mark" class="size-5" /></button>
          </div>
          <h2 id="delete-workspace-title">Delete {@deleting_workspace.name}?</h2>
          <p id="delete-workspace-description">
            This permanently deletes the workspace for everyone. This action cannot be undone.
          </p>
          <div class="workspace-delete-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div>
              <strong>Everything in this workspace will be removed</strong>
              <ul>
                <li>Boards, columns, and all work items</li>
                <li>Team chat and every private conversation</li>
                <li>Memberships and invitation links</li>
              </ul>
            </div>
          </div>
          <p class="workspace-delete-instruction">
            To confirm, enter <strong>{@deleting_workspace.name}</strong> below.
          </p>
          <.form
            for={@deletion_form}
            id="workspace-delete-form"
            class="workspace-form"
            phx-submit="confirm_delete_workspace"
          >
            <.input
              field={@deletion_form[:name]}
              id="delete-workspace-name"
              label="Workspace name"
              class="workspace-text-input"
              autocomplete="off"
              maxlength="80"
              required
              data-autofocus
            />
            <div class="workspace-delete-footer">
              <button
                id="cancel-delete-workspace"
                type="button"
                class="button button-secondary"
                phx-click="cancel_delete_workspace"
              >Keep workspace</button>
              <button
                id="confirm-delete-workspace"
                type="submit"
                class="button button-danger"
                phx-disable-with="Deleting…"
              ><.icon name="hero-trash" class="size-4" />Delete workspace</button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
