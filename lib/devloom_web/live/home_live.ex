defmodule DevloomWeb.HomeLive do
  use DevloomWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Foundation", check_count: 0)
     |> check_database()}
  end

  @impl true
  def handle_event("check_connection", _params, socket) do
    {:noreply,
     socket
     |> update(:check_count, &(&1 + 1))
     |> check_database()}
  end

  defp check_database(socket) do
    assign(socket,
      database_ready: Devloom.Health.check() == :ok,
      checked_at: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="overview" class="overview-heading">
        <div>
          <p class="eyebrow">WORKSPACE FOUNDATION</p>
          <h1>A good place to build together.</h1>
          <p class="page-intro">Your team's work, knowledge, and conversations. One shared home.</p>
        </div>
        <span class="version-label">FOUNDATION · v0.1</span>
      </div>

      <section class="welcome-panel" aria-labelledby="welcome-title">
        <div class="welcome-copy">
          <span class="hero-label"><span class="status-dot"></span> THE FIRST THREAD</span>
          <h2 id="welcome-title">Big ideas.<br />A shared starting point.</h2>
          <p>
            Devloom brings the pieces of your development workflow together, one module at a time.
          </p>
          <a href="#roadmap" class="build-plan-link">
            Explore the build plan <.icon name="hero-arrow-down" class="size-4" />
          </a>
        </div>
        <div class="loom-art" aria-hidden="true">
          <div class="loom-orbit orbit-one"></div>
          <div class="loom-orbit orbit-two"></div>
          <div class="loom-orbit orbit-three"></div>
          <div class="loom-tile tile-one"><.icon name="hero-rectangle-group" class="size-7" /></div>
          <div class="loom-tile tile-two"><.icon name="hero-code-bracket" class="size-8" /></div>
          <div class="loom-tile tile-three">
            <.icon name="hero-chat-bubble-left-right" class="size-6" />
          </div>
          <div class="loom-spark spark-one"></div>
          <div class="loom-spark spark-two"></div>
          <span class="art-caption">CONNECTED BY DESIGN</span>
        </div>
      </section>

      <div class="foundation-grid">
        <section class="foundation-card" aria-labelledby="foundation-title">
          <div class="section-heading">
            <div>
              <p class="eyebrow">READY TO BEGIN</p>
              <h2 id="foundation-title">A solid foundation.</h2>
            </div>
            <div class="section-icon"><.icon name="hero-command-line" class="size-5" /></div>
          </div>
          <p class="card-description">
            The application is running locally. Check the connection before we build the next module.
          </p>

          <div class="connection-row">
            <span class="connection-icon"><.icon name="hero-cube-transparent" class="size-5" /></span>
            <div class="connection-description">
              <h3>Phoenix application</h3>
              <p>Your workspace is up and running</p>
            </div>
            <span class="state-badge ready"><span></span> Running</span>
          </div>
          <div class="connection-row">
            <span class="connection-icon"><.icon name="hero-circle-stack" class="size-5" /></span>
            <div class="connection-description">
              <h3>PostgreSQL database</h3>
              <p>
                {if @database_ready,
                  do: "Connected and ready for your data",
                  else: "Connection needs attention"}
              </p>
            </div>
            <span
              id="database-status"
              data-status={if @database_ready, do: "ready", else: "unavailable"}
              class={["state-badge", if(@database_ready, do: "ready", else: "unavailable")]}
            >
              <span></span> {if @database_ready, do: "Connected", else: "Unavailable"}
            </span>
          </div>

          <div class="connection-footer">
            <p id="connection-feedback" data-check-count={@check_count} aria-live="polite">
              <%= if @check_count > 0 do %>
                {if @database_ready, do: "Connection confirmed", else: "Database unavailable"} · {@checked_at}
              <% else %>
                Last checked {@checked_at}
              <% end %>
            </p>
            <button
              id="check-connection"
              type="button"
              phx-click="check_connection"
              phx-disable-with="Checking…"
              class="check-button phx-click-loading:opacity-60"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Check connection
            </button>
          </div>
        </section>

        <aside class="next-card" aria-labelledby="next-title">
          <div class="next-label"><span></span> NEXT UP · MODULE 01</div>
          <div class="next-icon"><.icon name="hero-rectangle-group" class="size-7" /></div>
          <h2 id="next-title">Make work visible.</h2>
          <p>The Kanban board comes next. A clear view of what's planned, in progress, and done.</p>
          <div class="next-footer">
            <span>Kanban board</span><span class="planned-pill">Planned</span>
          </div>
        </aside>
      </div>

      <section id="roadmap" class="roadmap-section" aria-labelledby="roadmap-title">
        <div class="roadmap-heading">
          <div>
            <p class="eyebrow">BUILT ONE MODULE AT A TIME</p>
            <h2 id="roadmap-title">The path ahead.</h2>
          </div>
          <span class="roadmap-note">Foundation ready. Five modules ahead.</span>
        </div>
        <ol class="roadmap-list">
          <li class="roadmap-item">
            <span class="roadmap-number next-number">01</span>
            <div class="roadmap-icon"><.icon name="hero-rectangle-group" class="size-5" /></div>
            <div class="roadmap-copy">
              <h3>Kanban board</h3><p>See the flow of work</p>
            </div>
            <span class="roadmap-state next-state">Next</span>
          </li>
          <li class="roadmap-item">
            <span class="roadmap-number">02</span>
            <div class="roadmap-icon">
              <.icon name="hero-clipboard-document-check" class="size-5" />
            </div>
            <div class="roadmap-copy">
              <h3>Work items</h3><p>Give every task its context</p>
            </div>
            <span class="roadmap-state">Planned</span>
          </li>
          <li class="roadmap-item">
            <span class="roadmap-number">03</span>
            <div class="roadmap-icon"><.icon name="hero-document-text" class="size-5" /></div>
            <div class="roadmap-copy">
              <h3>Docs &amp; handbook</h3><p>Keep team knowledge close</p>
            </div>
            <span class="roadmap-state">Planned</span>
          </li>
          <li class="roadmap-item">
            <span class="roadmap-number">04</span>
            <div class="roadmap-icon">
              <.icon name="hero-chat-bubble-left-right" class="size-5" />
            </div>
            <div class="roadmap-copy">
              <h3>Team chat</h3><p>Keep the conversation connected</p>
            </div>
            <span class="roadmap-state">Planned</span>
          </li>
          <li class="roadmap-item">
            <span class="roadmap-number">05</span>
            <div class="roadmap-icon"><.icon name="hero-video-camera" class="size-5" /></div>
            <div class="roadmap-copy">
              <h3>Meetings</h3><p>Talk it through, together</p>
            </div>
            <span class="roadmap-state">Planned</span>
          </li>
        </ol>
      </section>
      <footer class="page-footer">
        <span>A little less scattered. A lot more connected.</span><span>Devloom · Team workspace</span>
      </footer>
    </Layouts.app>
    """
  end
end
