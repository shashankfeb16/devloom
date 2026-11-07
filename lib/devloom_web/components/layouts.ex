defmodule DevloomWeb.Layouts do
  @moduledoc "Application shell and shared feedback for Devloom."
  use DevloomWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="skip-link">Skip to content</a>
    <div class="workspace-shell">
      <aside class="workspace-sidebar" aria-label="Workspace navigation">
        <a href={~p"/"} class="brand" aria-label="Devloom home">
          <img src={~p"/images/logo.svg"} alt="" width="36" height="36" />
          <span>devloom<span class="brand-period">.</span></span>
        </a>
        <div class="workspace-label">
          <span class="workspace-avatar">D</span><div>
            <strong>Developer workspace</strong><span>Building, together</span>
          </div>
        </div>
        <nav class="primary-nav" aria-label="Primary">
          <p class="sidebar-eyebrow">WORKSPACE</p>
          <a href="#overview" class="nav-item active" aria-current="page"><.icon
            name="hero-squares-2x2"
            class="size-5"
          /><span>Overview</span><span class="nav-active-dot"></span></a>
          <a href="#roadmap" class="nav-item"><.icon name="hero-map" class="size-5" /><span>Build plan</span></a>
        </nav>
        <div class="sidebar-planned">
          <p class="sidebar-eyebrow">COMING TO YOUR WORKSPACE</p>
          <div class="planned-nav-item">
            <.icon name="hero-rectangle-group" class="size-4" /><span>Kanban board</span><small>Next</small>
          </div>
          <div class="planned-nav-item">
            <.icon name="hero-clipboard-document-check" class="size-4" /><span>Work items</span>
          </div>
          <div class="planned-nav-item">
            <.icon name="hero-document-text" class="size-4" /><span>Docs &amp; handbook</span>
          </div>
          <div class="planned-nav-item">
            <.icon name="hero-chat-bubble-left-right" class="size-4" /><span>Team chat</span>
          </div>
          <div class="planned-nav-item">
            <.icon name="hero-video-camera" class="size-4" /><span>Meetings</span>
          </div>
        </div>
        <div class="sidebar-bottom">
          <div class="sidebar-note">
            <span class="sidebar-note-icon"><.icon name="hero-sparkles" class="size-4" /></span><p>
              Small team.<br /><strong>Shared ambition.</strong>
            </p>
          </div>
          <div class="sidebar-environment">
            <span></span> LOCAL WORKSPACE <span class="environment-version">v0.1</span>
          </div>
        </div>
      </aside>
      <div class="workspace-body">
        <header class="workspace-topbar">
          <div class="breadcrumb">
            <span>Workspace</span><.icon name="hero-chevron-right" class="size-3" /><strong>Overview</strong>
          </div>
          <span class="local-badge"><span></span> Local development</span>
        </header>
        <main id="main-content" class="workspace-content">{render_slot(@inner_block)}</main>
      </div>
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
