defmodule DevloomWeb.MeetingLive do
  use DevloomWeb, :live_view

  alias Devloom.Meetings

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Meetings", meetings_configured: Meetings.configured?())}
  end

  @impl true
  def handle_event("enter_meeting", %{"action" => "start"}, socket), do: enter(socket, :start)

  def handle_event("enter_meeting", %{"action" => "join", "meeting_id" => id}, socket),
    do: enter(socket, {:join, id})

  def handle_event("enter_meeting", _params, socket),
    do: {:reply, %{status: "error", message: "This meeting is unavailable."}, socket}

  def handle_event("end_meeting", %{"id" => id}, socket) do
    case Meetings.end_meeting(socket.assigns.current_scope, id) do
      {:ok, _meeting} ->
        {:reply, %{status: "ok"}, assign(socket, :active_meeting, nil)}

      {:error, reason} ->
        message = error_message(reason)
        {:reply, %{status: "error", message: message}, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:workspace_access_changed, _id}, socket), do: {:noreply, socket}

  defp enter(socket, action) do
    case Meetings.join(socket.assigns.current_scope, action, socket.assigns.session_token) do
      {:ok, meeting, credentials} ->
        {:reply, Map.merge(credentials, %{status: "ok", meeting_id: meeting.id}),
         assign(socket, :active_meeting, meeting)}

      {:error, reason} ->
        socket = assign(socket, :active_meeting, Meetings.active(socket.assigns.current_scope))
        {:reply, %{status: "error", message: error_message(reason)}, socket}
    end
  end

  defp error_message(:no_meeting), do: "That meeting has ended. You can start a new one."
  defp error_message(:forbidden), do: "Your workspace access does not allow this action."
  defp error_message(:disabled), do: "Meetings are unavailable on this Devloom server."
  defp error_message(:unavailable), do: "The meeting server could not be reached. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="meetings">
      <section class="meeting-page" aria-labelledby="meeting-title">
        <header class="meeting-heading">
          <div>
            <h1 id="meeting-title">Meetings</h1>
            <p>Video calls for {@workspace.name}.</p>
          </div>
          <button
            :if={@active_meeting && Meetings.can_end?(@current_scope, @active_meeting)}
            id="end-meeting"
            type="button"
            class="button meeting-danger"
            phx-click="end_meeting"
            phx-value-id={@active_meeting.id}
            data-confirm="End this meeting for everyone?"
          >
            End for everyone
          </button>
        </header>

        <div :if={!@meetings_configured} id="meetings-unavailable" class="meeting-lobby">
          <.icon name="hero-video-camera-slash" class="size-7" />
          <h2>Meetings are unavailable</h2>
          <p>Contact your Devloom administrator to enable the meeting server.</p>
        </div>

        <div
          :if={@meetings_configured}
          id="meeting-room"
          phx-hook="MeetingRoom"
          phx-update="ignore"
          data-meeting-id={@active_meeting && @active_meeting.id}
          data-workspace-id={@workspace.id}
          data-workspace-name={@workspace.name}
          data-meeting-path={~p"/workspaces/#{@workspace.id}/meetings"}
        >
          <div data-meeting-lobby class="meeting-lobby">
            <div class="meeting-lobby-icon"><.icon name="hero-video-camera" class="size-7" /></div>
            <h2 data-meeting-lobby-title>
              {if @active_meeting, do: "Meeting in progress", else: "Ready to meet?"}
            </h2>
            <p>Your mic and camera are off when you join.</p>
            <button
              id="enter-meeting"
              data-action="enter"
              type="button"
              class="button button-primary"
              disabled
            >
              {if @active_meeting, do: "Join meeting", else: "Start meeting"}
            </button>
          </div>

          <p data-meeting-message class="meeting-message" role="status" hidden></p>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
