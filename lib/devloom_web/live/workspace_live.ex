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
          <span class="workspace-count"><.icon name="hero-squares-2x2" class="size-4" />{@workspace_count} {if @workspace_count ==
                                                                                                                 1,
                                                                                                               do:
                                                                                                                 "workspace",
                                                                                                               else:
                                                                                                                 "workspaces"}</span>
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
                  <span class={["workspace-role", workspace.role == :owner && "is-owner"]}>{if workspace.role ==
                                                                                                 :owner,
                                                                                               do:
                                                                                                 "Owner",
                                                                                               else:
                                                                                                 "Member"}</span>
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
    </Layouts.app>
    """
  end
end
