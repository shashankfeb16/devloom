defmodule DevloomWeb.RecordingsLive do
  use DevloomWeb, :live_view

  alias Devloom.Meetings.{Recordings, RecordingStorage, RecordingText}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Recordings.subscribe(socket.assigns.current_scope)
      RecordingText.subscribe(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Recordings",
       storage_configured: RecordingStorage.configured?(),
       transcript_configured: RecordingText.configured?(:transcript),
       summary_configured: RecordingText.configured?(:summary),
       selected: nil,
       transcript: nil,
       summary: nil,
       requested_text: MapSet.new()
     )
     |> stream_configure(:transcript_lines, dom_id: &"recording-transcript-line-#{&1.index}")
     |> stream(:transcript_lines, [])
     |> load_recordings()}
  end

  @impl true
  def handle_params(%{"recording_id" => id}, _uri, socket) do
    case Recordings.fetch(socket.assigns.current_scope, id) do
      {:ok, %{status: :ready} = recording} ->
        {:noreply, load_recording_text(socket, recording)}

      _ ->
        {:noreply, close_with_error(socket, "That recording is unavailable.")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(selected: nil, transcript: nil, summary: nil, requested_text: MapSet.new())
     |> stream(:transcript_lines, [], reset: true)}
  end

  @impl true
  def handle_event(
        "generate_recording_text",
        %{"kind" => kind},
        %{assigns: %{selected: %{id: id} = recording, current_scope: scope}} = socket
      )
      when kind in ["transcript", "summary"] do
    kind = if kind == "transcript", do: :transcript, else: :summary

    case RecordingText.request(scope, id, kind) do
      :ok ->
        {:noreply,
         socket
         |> update(:requested_text, &MapSet.put(&1, kind))
         |> load_recording_text(recording)}

      {:error, :disabled} ->
        {:noreply, close_with_error(socket, "Recording #{kind} generation is unavailable.")}

      {:error, :not_found} ->
        {:noreply, close_with_error(socket, "That recording is unavailable.")}
    end
  end

  def handle_event("generate_recording_text", _params, socket), do: {:noreply, socket}

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

  def handle_info({:recording_text_changed, id}, %{assigns: %{selected: %{id: id}}} = socket),
    do: handle_params(%{"recording_id" => id}, nil, socket)

  def handle_info({:recording_text_changed, _id}, socket), do: {:noreply, socket}

  defp load_recordings(socket) do
    stream(socket, :recordings, Recordings.list(socket.assigns.current_scope), reset: true)
  end

  defp load_recording_text(socket, recording) do
    jobs = RecordingText.for_recording(recording)

    requested =
      case socket.assigns.selected do
        %{id: id} when id == recording.id -> socket.assigns.requested_text
        _ -> MapSet.new()
      end

    case Enum.find(requested, &match?(%{status: :failed}, jobs[&1])) do
      nil ->
        pending =
          MapSet.filter(
            requested,
            &match?(%{status: status} when status in [:queued, :running], jobs[&1])
          )

        socket
        |> update_transcript(jobs[:transcript])
        |> assign(selected: recording, summary: jobs[:summary], requested_text: pending)

      kind ->
        close_with_error(socket, "Couldn’t generate the #{kind}. #{text_error(jobs[kind].error)}")
    end
  end

  defp update_transcript(%{assigns: %{transcript: transcript}} = socket, transcript), do: socket

  defp update_transcript(socket, transcript) do
    lines =
      if ready?(transcript) do
        Enum.with_index(transcript.result["segments"], fn line, index ->
          %{index: index, line: line}
        end)
      else
        []
      end

    socket
    |> assign(:transcript, transcript)
    |> stream(:transcript_lines, lines, reset: true)
  end

  defp close_with_error(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_patch(to: index_path(socket))
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

  defp ready?(job), do: match?(%{status: :ready}, job)
  defp can_request?(job), do: is_nil(job) or job.status == :failed

  defp text_error("no_audio"), do: "This recording has no audio track."
  defp text_error("audio_extraction_failed"), do: "Devloom couldn’t extract the recording audio."
  defp text_error("recording_unavailable"), do: "Devloom couldn’t read the saved recording."
  defp text_error("transcript_failed"), do: "The transcript couldn’t be generated."
  defp text_error("provider_account"), do: "Ask your Devloom administrator to check OpenRouter."
  defp text_error("provider_busy"), do: "OpenRouter is busy. Try again in a moment."
  defp text_error("provider_unavailable"), do: "The OpenRouter request failed. Try again."
  defp text_error("invalid_response"), do: "OpenRouter returned an incomplete result. Try again."
  defp text_error("interrupted"), do: "Generation was interrupted. Try again."
  defp text_error(_error), do: "Generation couldn’t finish. Try again."

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :show_text,
        assigns.summary_configured or assigns.transcript_configured or
          assigns.summary != nil or assigns.transcript != nil
      )

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
        class={["recording-dialog", @show_text && "recording-dialog-with-text"]}
        aria-labelledby="recording-player-title"
        phx-hook=".RecordingDialog"
        phx-mounted={JS.ignore_attributes("open")}
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
        <div class="recording-dialog-body">
          <div class="recording-media">
            <video
              id="recording-video"
              src={~p"/workspaces/#{@workspace.id}/recordings/#{@selected.id}/video"}
              controls
              playsinline
              preload="metadata"
              aria-label="Meeting recording"
              phx-update="ignore"
            >
              Your browser does not support video playback.
            </video>
            <p id="recording-playback-error" class="recording-playback-error" role="status" hidden>
              This video could not be loaded. Close and reopen the recording to try again.
            </p>
            <p :if={!@show_text} class="recording-text-unavailable">
              Transcript and summary generation are unavailable on this server.
            </p>
          </div>
          <aside
            :if={@show_text}
            class="recording-text-pane"
            aria-label="Recording transcript and summary"
          >
            <.text_panel
              kind="summary"
              title="Summary"
              icon="hero-sparkles"
              job={@summary}
              configured={@summary_configured && (@transcript_configured || ready?(@transcript))}
              waiting={!ready?(@transcript)}
              description="Create a recap with key points, decisions, and action items."
            >
              <div :if={ready?(@summary)} id="recording-summary-result" class="recording-summary">
                <p>{@summary.result["overview"]}</p>
                <.summary_list title="Key points" items={@summary.result["key_points"]} />
                <.summary_list title="Decisions" items={@summary.result["decisions"]} />
                <.summary_list title="Action items" items={@summary.result["action_items"]} />
              </div>
            </.text_panel>

            <.text_panel
              kind="transcript"
              title="Transcript"
              icon="hero-document-text"
              job={@transcript}
              configured={@transcript_configured}
              description="Read what was said and jump to a moment in the recording."
            >
              <div :if={ready?(@transcript)} id="recording-transcript-result">
                <p :if={@transcript.result["text"] == ""} class="recording-text-status">
                  No speech was detected in this recording.
                </p>
                <p :if={@transcript.result["part_count"] > 1} class="recording-text-status">
                  Speaker numbers are assigned separately in each part.
                </p>
                <ul id="recording-transcript-lines" phx-update="stream" class="recording-transcript">
                  <li :for={{id, item} <- @streams.transcript_lines} id={id}>
                    <button
                      type="button"
                      class="recording-timestamp"
                      data-recording-seek={item.line["start_ms"] / 1_000}
                      aria-label={"Jump to #{duration(div(item.line["start_ms"], 1_000))}"}
                    >
                      {duration(div(item.line["start_ms"], 1_000))}
                    </button>
                    <div>
                      <span :if={item.line["speaker"]} class="recording-speaker">
                        Speaker {item.line["speaker"]}
                        <span :if={@transcript.result["part_count"] > 1}>
                          · Part {item.line["part"]}
                        </span>
                      </span>
                      <p>{item.line["text"]}</p>
                    </div>
                  </li>
                </ul>
              </div>
            </.text_panel>
            <p :if={@transcript_configured || @summary_configured} class="recording-text-provider">
              OpenRouter processes recording audio for transcripts and transcript text for summaries.
            </p>
          </aside>
        </div>
      </dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RecordingDialog">
        export default {
          mounted() {
            this.opener = document.activeElement
            this.video = this.el.querySelector("video")
            this.el.addEventListener("cancel", event => {
              event.preventDefault()
              this.el.querySelector("#close-recording").click()
            })
            this.video.addEventListener("error", () => {
              this.el.querySelector("#recording-playback-error").hidden = false
            })
            this.video.addEventListener("loadedmetadata", () => this.seek())
            this.el.addEventListener("click", event => {
              if (event.target.closest("#close-recording")) {
                this.el.close()
                return
              }
              const timestamp = event.target.closest("[data-recording-seek]")
              if (!timestamp) return
              this.pendingSeek = Number(timestamp.dataset.recordingSeek)
              if (this.video.readyState >= HTMLMediaElement.HAVE_METADATA) this.seek()
              this.video.scrollIntoView({ block: "nearest" })
            })
            this.el.showModal()
          },
          seek() {
            if (!Number.isFinite(this.pendingSeek)) return
            this.video.currentTime = Math.min(this.pendingSeek, this.video.duration || Infinity)
            this.pendingSeek = null
          },
          destroyed() {
            this.el.close()
            if (this.opener?.isConnected) this.opener.focus()
          },
        }
      </script>
    </Layouts.app>
    """
  end

  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :job, :any, required: true
  attr :configured, :boolean, required: true
  attr :description, :string, required: true
  attr :waiting, :boolean, default: false
  slot :inner_block, required: true

  defp text_panel(assigns) do
    ~H"""
    <section
      id={"recording-#{@kind}"}
      class="recording-text-panel"
      aria-labelledby={"recording-#{@kind}-title"}
    >
      <header>
        <h3 id={"recording-#{@kind}-title"}>
          <.icon name={@icon} class="size-4" /> {@title}
        </h3>
        <button
          :if={@configured && can_request?(@job)}
          id={"generate-recording-#{@kind}"}
          type="button"
          class="button"
          phx-click="generate_recording_text"
          phx-value-kind={@kind}
          phx-disable-with="Queuing…"
        >
          {if @job, do: "Retry #{@kind}", else: "Generate #{@kind}"}
        </button>
      </header>
      <div id={"recording-#{@kind}-status"} role="status" class={ready?(@job) && "sr-only"}>
        <%= cond do %>
          <% ready?(@job) -> %>
            {@title} ready.
          <% !@configured -> %>
            <p class="recording-text-status">Generation is unavailable.</p>
          <% is_nil(@job) -> %>
            <p class="recording-text-status">{@description}</p>
          <% @job.status == :failed -> %>
            <p class="recording-text-status recording-text-error">{text_error(@job.error)}</p>
          <% true -> %>
            <p class="recording-text-status recording-text-progress">
              <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
              {cond do
                @waiting -> "Waiting for the transcript…"
                @job.status == :queued -> "Queued…"
                true -> "Generating #{@kind}…"
              end}
            </p>
        <% end %>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true

  defp summary_list(assigns) do
    ~H"""
    <div :if={@items != []}>
      <h4>{@title}</h4>
      <ul>
        <li :for={item <- @items}>{item}</li>
      </ul>
    </div>
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
