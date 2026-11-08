defmodule DevloomWeb.Layouts do
  @moduledoc "Application shell and shared feedback for Devloom."
  use DevloomWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active_view, :string, default: "board"
  slot :inner_block, required: true

  def app(%{current_scope: nil} = assigns) do
    ~H"""
    <div class="auth-shell">
      <header class="auth-topbar">
        <.link href={~p"/"} class="brand" aria-label="Devloom home">
          <img src={~p"/images/logo.svg"} alt="" width="29" height="29" /><span>devloom</span>
        </.link>
        <nav aria-label="Account navigation">
          <.link href={~p"/users/log_in"}>Sign in</.link>
          <.link href={~p"/users/register"} class="button button-primary">Create account</.link>
        </nav>
      </header>
      <main id="main-content" class="auth-main">{render_slot(@inner_block)}</main>
      <footer class="auth-page-footer">A little less overhead. A little more building.</footer>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    assigns = assign(assigns, :workspace, assigns.current_scope.workspace)

    ~H"""
    <a href="#main-content" class="skip-link">Skip to content</a>
    <div class="workspace-shell">
      <header class="workspace-topbar">
        <.link navigate={~p"/workspaces"} class="brand" aria-label="Devloom home">
          <img src={~p"/images/logo.svg"} alt="" width="29" height="29" /><span>devloom</span>
        </.link>
        <nav class="breadcrumb" aria-label="Breadcrumb">
          <.link navigate={~p"/workspaces"}>Workspaces</.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <span :if={@workspace}>{@workspace.name}</span>
          <.icon :if={@workspace} name="hero-chevron-right" class="size-3" />
          <strong>{view_title(@active_view)}</strong>
        </nav>
        <div class="topbar-right">
          <span
            id="board-live-status"
            class="live-status"
            phx-connected={JS.remove_class("offline")}
            phx-disconnected={JS.add_class("offline")}
          >
            <span class="live-dot"></span><span class="live-label">Live sync</span><span class="reconnect-label">Reconnecting</span>
          </span>
          <span class="topbar-divider"></span>
          <span class="guest-avatar" title={@current_scope.user.email}>{initials(
            @current_scope.user.name
          )}</span>
          <.link
            id="sign-out"
            href={~p"/users/log_out"}
            method="delete"
            class="account-sign-out"
            aria-label="Sign out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /><span>Sign out</span>
          </.link>
        </div>
      </header>
      <nav class="workspace-mobile-nav" aria-label="Mobile workspace navigation">
        <.link
          id="mobile-nav-workspaces"
          navigate={~p"/workspaces"}
          class={@active_view == "workspaces" && "active"}
        >
          <.icon name="hero-squares-2x2" class="size-4" />Workspaces
        </.link>
        <.link
          :if={@workspace}
          id="mobile-nav-board"
          navigate={~p"/workspaces/#{@workspace.id}/board"}
          class={@active_view in ["board", "list"] && "active"}
        >
          <.icon name="hero-view-columns" class="size-4" />Board
        </.link>
        <.link
          :if={@workspace}
          id="mobile-nav-chat"
          navigate={~p"/workspaces/#{@workspace.id}/chat"}
          class={@active_view == "chat" && "active"}
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" />Chat
        </.link>
        <.link
          :if={@workspace}
          id="mobile-nav-members"
          navigate={~p"/workspaces/#{@workspace.id}/members"}
          class={@active_view == "members" && "active"}
        >
          <.icon name="hero-user-group" class="size-4" />Members
        </.link>
      </nav>
      <aside class="workspace-sidebar" aria-label="Workspace navigation">
        <.link id="workspace-switcher" navigate={~p"/workspaces"} class="project-switcher">
          <span class="project-avatar">{if @workspace, do: initials(@workspace.name), else: "D"}</span>
          <div>
            <strong>{if @workspace, do: @workspace.name, else: "Your workspaces"}</strong><span>Switch workspace</span>
          </div>
          <.icon name="hero-chevron-up-down" class="project-local size-4" />
        </.link>
        <nav class="primary-nav" aria-label="Project">
          <p class="sidebar-eyebrow">YOUR WORKSPACES</p>
          <.link
            id="nav-workspaces"
            navigate={~p"/workspaces"}
            class={["nav-item", "workspace-chat-link", @active_view == "workspaces" && "active"]}
            aria-current={@active_view == "workspaces" && "page"}
          >
            <.icon name="hero-squares-2x2" class="size-[18px]" /><span>All workspaces</span>
          </.link>
          <div :if={@workspace} class="sidebar-rule"></div>
          <p :if={@workspace} class="sidebar-eyebrow">WORKSPACE</p>
          <.link
            :if={@workspace}
            id="nav-board"
            navigate={~p"/workspaces/#{@workspace.id}/board"}
            class={["nav-item", "workspace-chat-link", @active_view == "board" && "active"]}
            aria-current={@active_view == "board" && "page"}
          >
            <.icon name="hero-view-columns" class="size-4" /><span>Team board</span>
          </.link>
          <.link
            :if={@workspace}
            id="nav-work-items"
            navigate={~p"/workspaces/#{@workspace.id}/board?view=list"}
            class={["nav-item", "workspace-chat-link", @active_view == "list" && "active"]}
            aria-current={@active_view == "list" && "page"}
          >
            <.icon name="hero-clipboard-document-list" class="size-4" /><span>Work items</span>
          </.link>
          <.link
            :if={@workspace}
            id="nav-chat"
            navigate={~p"/workspaces/#{@workspace.id}/chat"}
            class={["nav-item", "workspace-chat-link", @active_view == "chat" && "active"]}
            aria-current={@active_view == "chat" && "page"}
          >
            <.icon name="hero-chat-bubble-left-right" class="size-[18px]" /><span>Team chat</span>
          </.link>
          <.link
            :if={@workspace}
            id="nav-members"
            navigate={~p"/workspaces/#{@workspace.id}/members"}
            class={["nav-item", "workspace-chat-link", @active_view == "members" && "active"]}
            aria-current={@active_view == "members" && "page"}
          >
            <.icon name="hero-user-group" class="size-[18px]" /><span>Members &amp; invites</span>
          </.link>
          <div class="sidebar-rule"></div>
          <div class="planned-nav-item" aria-disabled="true">
            <.icon name="hero-book-open" class="size-[18px]" /><span>Documentation</span><small>Soon</small>
          </div>
          <div class="planned-nav-item" aria-disabled="true">
            <.icon name="hero-video-camera" class="size-[18px]" /><span>Meetings</span><small>Soon</small>
          </div>
        </nav>
        <div class="sidebar-bottom">
          <div class="workspace-note">
            <span class="note-icon"><.icon name="hero-command-line" class="size-[18px]" /></span><strong>A little less overhead.<br />A little more building.</strong><p>
              Your team's work, in one place.
            </p>
          </div>
          <.link
            :if={@workspace}
            id="board-help"
            navigate={~p"/workspaces/#{@workspace.id}/board?help=1"}
            class="sidebar-help"
          ><.icon name="hero-question-mark-circle" class="size-[18px]" /><span>Board help</span></.link>
          <div class="sidebar-identity">
            <span class="identity-icon"><.icon name="hero-user" class="size-4" /></span><div>
              <strong>{@current_scope.user.name}</strong><span>{if @current_scope.membership,
                do: String.capitalize(to_string(@current_scope.membership.role)),
                else: "Your developer workspace"}</span>
            </div>
          </div>
        </div>
      </aside>
      <main id="main-content" class="workspace-content">{render_slot(@inner_block)}</main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  defp view_title("chat"), do: "Team chat"
  defp view_title("members"), do: "Members"
  defp view_title("workspaces"), do: "Your workspaces"
  defp view_title("list"), do: "Work items"
  defp view_title(_), do: "Team board"

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="Connection interrupted"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting to your workspace
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title="The workspace needs a moment"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
