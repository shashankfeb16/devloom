defmodule DevloomWeb.Layouts do
  @moduledoc "Application shell and shared feedback for Devloom."
  use DevloomWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active_view, :string, default: "board"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="skip-link">Skip to content</a>
    <div class="workspace-shell">
      <header class="workspace-topbar">
        <.link navigate={~p"/"} class="brand" aria-label="Devloom home">
          <img src={~p"/images/logo.svg"} alt="" width="29" height="29" />
          <span>devloom</span>
        </.link>
        <nav class="breadcrumb" aria-label="Breadcrumb">
          <span>Workspace</span><.icon name="hero-chevron-right" class="size-3" />
          <span>Devloom</span><.icon name="hero-chevron-right" class="size-3" />
          <strong>{if @active_view == "chat", do: "Team chat", else: "Boards"}</strong>
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
          <span class="guest-avatar" title="Guest workspace — accounts will be added later"><.icon
            name="hero-user"
            class="size-4"
          /></span>
        </div>
      </header>
      <nav class="workspace-mobile-nav" aria-label="Mobile workspace navigation">
        <.link
          id="mobile-nav-board"
          navigate={~p"/"}
          class={@active_view != "chat" && "active"}
          aria-current={@active_view != "chat" && "page"}
        >
          <.icon name="hero-view-columns" class="size-4" />Team board
        </.link>
        <.link
          id="mobile-nav-chat"
          navigate={~p"/chat"}
          class={@active_view == "chat" && "active"}
          aria-current={@active_view == "chat" && "page"}
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" />Team chat
        </.link>
      </nav>
      <aside class="workspace-sidebar" aria-label="Workspace navigation">
        <div class="project-switcher">
          <span class="project-avatar">D</span>
          <div><strong>Devloom</strong><span>Developer workspace</span></div>
          <span class="project-local" title="Local project"><.icon
            name="hero-code-bracket"
            class="size-4"
          /></span>
        </div>
        <nav class="primary-nav" aria-label="Project">
          <p class="sidebar-eyebrow">PROJECT</p>
          <div class="nav-section">
            <.icon name="hero-rectangle-group" class="size-[18px]" /><span>Boards</span><.icon
              name="hero-chevron-down"
              class="ml-auto size-3"
            />
          </div>
          <button
            :if={@active_view != "chat"}
            id="nav-board"
            class={["nav-item", @active_view == "board" && "active"]}
            phx-click="switch_view"
            phx-value-view="board"
            aria-current={@active_view == "board" && "page"}
          >
            <.icon name="hero-view-columns" class="size-4" /><span>Team board</span>
          </button>
          <.link :if={@active_view == "chat"} id="nav-board" navigate={~p"/"} class="nav-item">
            <.icon name="hero-view-columns" class="size-4" /><span>Team board</span>
          </.link>
          <button
            :if={@active_view != "chat"}
            id="nav-work-items"
            class={["nav-item", @active_view == "list" && "active"]}
            phx-click="switch_view"
            phx-value-view="list"
            aria-current={@active_view == "list" && "page"}
          >
            <.icon name="hero-clipboard-document-list" class="size-4" /><span>Work items</span>
          </button>
          <.link
            :if={@active_view == "chat"}
            id="nav-work-items"
            navigate={~p"/?view=list"}
            class="nav-item"
          >
            <.icon name="hero-clipboard-document-list" class="size-4" /><span>Work items</span>
          </.link>
          <div class="sidebar-rule"></div>
          <p class="sidebar-eyebrow">YOUR WORKSPACE</p>
          <.link
            id="nav-chat"
            navigate={~p"/chat"}
            class={["nav-item", "workspace-chat-link", @active_view == "chat" && "active"]}
            aria-current={@active_view == "chat" && "page"}
          >
            <.icon name="hero-chat-bubble-left-right" class="size-[18px]" /><span>Team chat</span>
          </.link>
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
          <button
            :if={@active_view != "chat"}
            id="board-help"
            class="sidebar-help"
            phx-click="show_help"
          ><.icon
            name="hero-question-mark-circle"
            class="size-[18px]"
          /><span>Help &amp; shortcuts</span><kbd>?</kbd></button>
          <.link
            :if={@active_view == "chat"}
            id="board-help"
            navigate={~p"/?help=1"}
            class="sidebar-help"
          >
            <.icon name="hero-question-mark-circle" class="size-[18px]" /><span>Board help</span>
          </.link>
          <div class="sidebar-identity">
            <span class="identity-icon"><.icon name="hero-user-group" class="size-4" /></span><div>
              <strong>Shared workspace</strong><span>Working together, in real time</span>
            </div>
          </div>
        </div>
      </aside>
      <main id="main-content" class="workspace-content">{render_slot(@inner_block)}</main>
    </div>
    <.flash_group flash={@flash} />
    """
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
