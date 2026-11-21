defmodule DevloomWeb.MeetingLive do
  use DevloomWeb, :live_view

  alias Devloom.Meetings
  alias Devloom.Meetings.{Recordings, Transcripts}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Recordings.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: "Meetings",
       meetings_configured: Meetings.configured?(),
       recordings_configured: Recordings.configured?(),
       transcripts_configured: Transcripts.configured?()
     )
     |> refresh_recording()}
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

  def handle_event("recording_control", %{"action" => action, "id" => id}, socket)
      when action in ["start", "stop"] do
    scope = socket.assigns.current_scope

    result =
      if action == "start", do: Recordings.start(scope, id), else: Recordings.stop(scope, id)

    socket = refresh_recording(socket)

    case result do
      :ok ->
        {:reply, %{status: "ok"}, socket}

      {:error, :disabled} ->
        {:reply, %{status: "error", message: "Recording is unavailable on this Devloom server."},
         socket}

      {:error, reason} ->
        {:reply, %{status: "error", message: error_message(reason)}, socket}
    end
  end

  def handle_event("transcript_control", %{"action" => action, "id" => id}, socket)
      when action in ["start", "stop"] do
    %{current_scope: scope, session_token: token} = socket.assigns

    case Transcripts.control(scope, id, token, action) do
      :ok ->
        {:reply, %{status: "ok"}, socket}

      {:error, reason} ->
        {:reply, %{status: "error", message: transcript_error_message(reason)}, socket}
    end
  end

  @impl true
  def handle_info(:recordings_changed, socket), do: {:noreply, refresh_recording(socket)}

  def handle_info({:workspace_access_changed, _id}, socket), do: {:noreply, socket}

  defp enter(socket, action) do
    case Meetings.join(socket.assigns.current_scope, action, socket.assigns.session_token) do
      {:ok, meeting, credentials} ->
        {:reply, Map.merge(credentials, %{status: "ok", meeting_id: meeting.id}),
         socket |> assign(:active_meeting, meeting) |> refresh_recording()}

      {:error, reason} ->
        socket = assign(socket, :active_meeting, Meetings.active(socket.assigns.current_scope))
        {:reply, %{status: "error", message: error_message(reason)}, socket}
    end
  end

  defp refresh_recording(socket) do
    assign(socket, :active_recording, Recordings.active(socket.assigns.active_meeting))
  end

  defp transcript_error_message(:disabled),
    do: "Live transcription is unavailable on this server."

  defp transcript_error_message(:unavailable),
    do: "The transcription service could not complete that action. Try again."

  defp transcript_error_message(:not_in_call), do: "Join the call before starting the transcript."
  defp transcript_error_message(reason), do: error_message(reason)

  defp error_message(:recording_in_progress), do: "A recording is already in progress."
  defp error_message(:no_recording), do: "There is no recording to stop."
  defp error_message(:rejected), do: "The recording service could not complete that action."

  defp error_message(:recording_unavailable),
    do: "The recording service could not start the recording."

  defp error_message(:recording_start_unknown),
    do: "The recording service did not respond. Checking whether recording started."

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
          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={~p"/workspaces/#{@workspace.id}/recordings"}
              class="button"
              id="meeting-recordings-link"
            >
              <.icon name="hero-film" class="size-4" /> Recordings
            </.link>
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
          </div>
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
          data-recording-status={
            @active_meeting && @active_recording &&
              @active_meeting.id == @active_recording.meeting_id && @active_recording.status
          }
          data-can-record={
            to_string(@active_meeting != nil and Meetings.can_end?(@current_scope, @active_meeting))
          }
          data-recordings-configured={to_string(@recordings_configured)}
          data-transcripts-configured={to_string(@transcripts_configured)}
          data-can-transcribe={
            to_string(@active_meeting != nil and Meetings.can_end?(@current_scope, @active_meeting))
          }
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
