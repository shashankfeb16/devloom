defmodule DevloomWeb.RecordingsLive do
  use DevloomWeb, :live_view

  alias Devloom.Meetings.Recordings
  alias Devloom.Meetings.RecordingStorage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Recordings.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(page_title: "Recordings", storage_configured: RecordingStorage.configured?())
     |> load_recordings()}
  end

  @impl true
  def handle_params(%{"recording_id" => id}, _uri, socket) do
    case Recordings.fetch(socket.assigns.current_scope, id) do
      {:ok, %{status: :ready} = recording} ->
        {:noreply, assign(socket, :selected, recording)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "That recording is unavailable.")
         |> push_patch(to: index_path(socket))}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :selected, nil)}

  @impl true
  def handle_event("close_recording", _params, socket),
    do: {:noreply, push_patch(socket, to: index_path(socket))}

  def handle_event("delete_recording", %{"id" => id}, socket) do
    case Recordings.delete(socket.assigns.current_scope, id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Recording deleted.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the workspace owner can delete recordings.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete this recording. Try again.")}
    end
  end

  @impl true
  def handle_info(:recordings_changed, socket) do
    socket = load_recordings(socket)

    case socket.assigns.selected do
      nil -> {:noreply, socket}
      recording -> handle_params(%{"recording_id" => recording.id}, nil, socket)
    end
  end

  def handle_info({:workspace_access_changed, _id}, socket),
    do: {:noreply, load_recordings(socket)}

  defp load_recordings(socket) do
    stream(socket, :recordings, Recordings.list(socket.assigns.current_scope), reset: true)
  end

  defp index_path(socket), do: ~p"/workspaces/#{socket.assigns.workspace.id}/recordings"

  defp duration(nil), do: nil

  defp duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    seconds = rem(seconds, 60)
    parts = if hours > 0, do: [hours, minutes, seconds], else: [minutes, seconds]
    [first | rest] = parts

    Enum.join([first | Enum.map(rest, &String.pad_leading(to_string(&1), 2, "0"))], ":")
  end

  defp file_size(nil), do: nil
  defp file_size(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp file_size(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp file_size(bytes) when bytes < 1_000_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp file_size(bytes), do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"

  defp recording_date(recording), do: Calendar.strftime(recording.inserted_at, "%b %-d, %Y")
  defp recording_time(recording), do: Calendar.strftime(recording.inserted_at, "%H:%M UTC")

  defp status_label(:starting), do: "Starting recording"
  defp status_label(:recording), do: "Recording in progress"
  defp status_label(:processing), do: "Saving video"
  defp status_label(:failed), do: "Recording failed"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="recordings">
      <section id="workspace-recordings" class="meeting-page" aria-labelledby="recordings-title">
        <header class="meeting-heading">
          <div>
            <h1 id="recordings-title">Recordings</h1>
            <p>Meeting videos saved in {@workspace.name}.</p>
          </div>
          <.link
            id="recordings-meetings-link"
            navigate={~p"/workspaces/#{@workspace.id}/meetings"}
            class="button"
          >
            <.icon name="hero-video-camera" class="size-4" /> Go to meetings
          </.link>
        </header>

        <div id="recordings-list" class="recordings-list" phx-update="stream">
          <div id="recordings-empty" class="recordings-empty hidden only:grid">
            <div class="meeting-lobby-icon"><.icon name="hero-film" class="size-6" /></div>
            <h2>
              {if @storage_configured, do: "No recordings yet", else: "Recordings are unavailable"}
            </h2>
            <p>
              {if @storage_configured,
                do: "Record a meeting and its video will appear here.",
                else: "Ask your Devloom administrator to enable recording storage."}
            </p>
          </div>

          <article :for={{id, recording} <- @streams.recordings} id={id} class="recording-row">
            <.link
              :if={recording.status == :ready}
              patch={~p"/workspaces/#{@workspace.id}/recordings/#{recording.id}"}
              class="recording-row-main recording-row-link"
              id={"play-recording-#{recording.id}"}
            >
              <.recording_details recording={recording} />
            </.link>
            <div :if={recording.status != :ready} class="recording-row-main">
              <.recording_details recording={recording} />
            </div>
            <button
              :if={@current_scope.membership.role == :owner && recording.status in [:ready, :failed]}
              id={"delete-recording-#{recording.id}"}
              type="button"
              class="recording-delete"
              phx-click="delete_recording"
              phx-value-id={recording.id}
              phx-disable-with="Deleting…"
              data-confirm="Permanently delete this workspace recording?"
              title="Delete recording"
              aria-label={"Delete recording from #{recording_date(recording)} at #{recording_time(recording)}"}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </article>
        </div>
      </section>

      <dialog
        :if={@selected}
        id={"recording-player-#{@selected.id}"}
        class="recording-dialog"
        aria-labelledby="recording-player-title"
        phx-hook=".RecordingDialog"
      >
        <header class="recording-dialog-header">
          <div>
            <h2 id="recording-player-title">Workspace meeting</h2>
            <p>
              {recording_date(@selected)} · {recording_time(@selected)}<span :if={
                @selected.size_bytes
              }> · {file_size(@selected.size_bytes)}</span>
            </p>
          </div>
          <div class="recording-dialog-actions">
            <a
              id="download-recording"
              href={~p"/workspaces/#{@workspace.id}/recordings/#{@selected.id}/video?download=1"}
              class="button"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download
            </a>
            <.link
              patch={~p"/workspaces/#{@workspace.id}/recordings"}
              id="close-recording"
              class="button"
              aria-label="Close recording"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </.link>
          </div>
        </header>
        <video
          id="recording-video"
          src={~p"/workspaces/#{@workspace.id}/recordings/#{@selected.id}/video"}
          controls
          playsinline
          preload="metadata"
          aria-label="Meeting recording"
        >
          Your browser does not support video playback.
        </video>
        <p id="recording-playback-error" class="recording-playback-error" role="status" hidden>
          This video could not be loaded. Close and reopen the recording to try again.
        </p>
      </dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RecordingDialog">
        export default {
          mounted() {
            this.opener = document.activeElement
            this.el.addEventListener("cancel", event => {
              event.preventDefault()
              this.pushEvent("close_recording", {})
            })
            this.el.querySelector("video").addEventListener("error", () => {
              this.el.querySelector("#recording-playback-error").hidden = false
            })
            this.el.showModal()
          },
          destroyed() {
            if (this.opener?.isConnected) this.opener.focus()
          },
        }
      </script>
    </Layouts.app>
    """
  end

  attr :recording, :map, required: true

  defp recording_details(assigns) do
    ~H"""
    <span class="recording-thumbnail">
      <.icon
        name={if @recording.status == :ready, do: "hero-play-solid", else: "hero-film"}
        class="size-5"
      />
      <span :if={@recording.duration_seconds} class="recording-duration">{duration(
        @recording.duration_seconds
      )}</span>
    </span>
    <span class="recording-details">
      <strong>Workspace meeting</strong>
      <span>
        Started by {if @recording.started_by, do: @recording.started_by.name, else: "a former member"}<span :if={
          @recording.size_bytes
        }> · {file_size(@recording.size_bytes)}</span>
      </span>
    </span>
    <span :if={@recording.status != :ready} class="recording-status" data-status={@recording.status}>
      {status_label(@recording.status)}
    </span>
    <time datetime={DateTime.to_iso8601(@recording.inserted_at)} class="recording-time">
      <span>{recording_date(@recording)}</span>
      <small>{recording_time(@recording)}</small>
    </time>
    """
  end
end
