defmodule Devloom.Meetings.Recordings do
  @moduledoc "Recording lifecycle and workspace access."
  import Ecto.Query

  alias Devloom.Accounts.Scope
  alias Devloom.Meetings.{LiveKit, Meeting, Recording, RecordingStorage}
  alias Devloom.Workspaces.{Membership, Workspace}
  alias Devloom.{Meetings, Repo, Workspaces}

  @pending [:starting, :recording, :processing]
  @settle_seconds 60

  def configured?, do: LiveKit.configured?() and RecordingStorage.configured?()

  def subscribe(%Scope{workspace: %Workspace{id: id}}),
    do: Phoenix.PubSub.subscribe(Devloom.PubSub, topic(id))

  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    if Workspaces.authorized_scope?(scope) do
      Repo.all(
        from r in Recording,
          where: r.workspace_id == ^workspace_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          preload: :started_by
      )
    else
      []
    end
  end

  def fetch(%Scope{workspace: %Workspace{id: workspace_id}} = scope, id) do
    with true <- Workspaces.authorized_scope?(scope),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Recording{} = recording <- Repo.get_by(Recording, id: id, workspace_id: workspace_id) do
      {:ok, Repo.preload(recording, :started_by)}
    else
      _ -> {:error, :not_found}
    end
  end

  def active(nil), do: nil

  def active(%Meeting{id: meeting_id}) do
    Repo.one(from r in Recording, where: r.meeting_id == ^meeting_id and r.status in ^@pending)
  end

  def start(scope, meeting_id) do
    with true <- configured?() || {:error, :disabled},
         {:ok, recording} <-
           Meetings.with_control(scope, meeting_id, fn scope, meeting ->
             if active(meeting), do: Repo.rollback(:recording_in_progress)

             Repo.insert!(%Recording{
               workspace_id: scope.workspace.id,
               meeting_id: meeting.id,
               started_by_id: scope.user.id,
               status: :starting
             })
           end) do
      broadcast(recording.workspace_id)

      # Keep the reservation committed before making the remote request.
      run_control(fn -> start_egress(recording) end)
    end
  end

  def stop(scope, meeting_id) do
    with true <- configured?() || {:error, :disabled},
         {:ok, recording} <-
           Meetings.with_control(scope, meeting_id, fn _scope, meeting ->
             case active(meeting) do
               %Recording{status: status, egress_id: id} = recording
               when status in [:starting, :recording] and is_binary(id) ->
                 recording

               _ ->
                 Repo.rollback(:no_recording)
             end
           end) do
      run_control(fn -> stop_egress(recording) end)
    end
  end

  @doc false
  def stop_before_room_close(meeting) do
    if configured?() do
      case active(meeting) do
        %Recording{status: status, egress_id: id}
        when status in [:starting, :recording] and is_binary(id) ->
          LiveKit.stop_recording(id)

        _ ->
          :ok
      end
    end
  end

  def delete(%Scope{workspace: %Workspace{id: workspace_id}} = scope, id) do
    result =
      Repo.transaction(fn ->
        Repo.one(from w in Workspace, where: w.id == ^workspace_id, lock: "FOR UPDATE") ||
          Repo.rollback(:forbidden)

        case Workspaces.fetch_scope(scope, workspace_id) do
          {:ok, %Scope{membership: %Membership{role: :owner}}} -> :ok
          _ -> Repo.rollback(:forbidden)
        end

        case fetch(scope, id) do
          {:ok, %Recording{status: status} = recording} when status in [:ready, :failed] ->
            with true <- RecordingStorage.configured?(),
                 :ok <- RecordingStorage.delete(recording) do
              Repo.delete!(recording)
            else
              _ -> Repo.rollback(:unavailable)
            end

          _ ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, _recording} -> broadcast(workspace_id)
      other -> other
    end
  end

  def reconcile do
    if configured?() do
      Repo.all(from r in Recording, where: r.status in ^@pending)
      |> Enum.each(&reconcile_recording/1)
    end

    if RecordingStorage.configured?() do
      # Workspace deletion removes access immediately, while keeping enough
      # information to retry storage cleanup after an in-flight job finishes.
      for recording <-
            Repo.all(
              from r in Recording,
                where: is_nil(r.workspace_id) and r.status not in ^@pending
            ) do
        if RecordingStorage.delete(recording) == :ok do
          Repo.delete(recording, allow_stale: true)
        end
      end
    end
  end

  # A meeting view can disconnect as soon as a user navigates to Recordings.
  # Keep its authorized request running until the remote operation is handled.
  defp run_control(fun) do
    Devloom.Meetings.RecordingTasks
    |> Task.Supervisor.async_nolink(fun)
    |> Task.await(:infinity)
  end

  defp start_egress(recording) do
    case LiveKit.start_recording(room_name(recording), Recording.object_key(recording)) do
      {:ok, %{id: id} = info} when is_binary(id) ->
        apply_info(recording, info)
        :ok

      {:error, reason} when reason in [:rejected, :not_found] ->
        update_pending(recording, %{status: :failed})
        {:error, :recording_unavailable}

      _ ->
        {:error, :recording_start_unknown}
    end
  end

  defp stop_egress(recording) do
    with {:ok, info} <- LiveKit.stop_recording(recording.egress_id) do
      # A successful stop can return ENDING or a terminal status.
      info =
        if info.status in [:starting, :recording], do: %{info | status: :processing}, else: info

      apply_info(recording, info)
      :ok
    end
  end

  defp reconcile_recording(recording) do
    case LiveKit.recording_info(
           room_name(recording),
           recording.egress_id,
           Recording.object_key(recording)
         ) do
      {:ok, info} ->
        apply_info(recording, info)

        if is_binary(info.id) && info.status in [:starting, :recording] &&
             !Repo.exists?(
               from m in Meeting,
                 where: m.id == ^recording.meeting_id and not is_nil(m.workspace_id)
             ) do
          case LiveKit.stop_recording(info.id) do
            {:ok, stopped} -> apply_info(recording, stopped)
            {:error, _} -> :ok
          end
        end

      {:error, :not_found} ->
        recover_missing_job(recording)

      {:error, _} ->
        :ok
    end
  end

  defp recover_missing_job(recording) do
    if DateTime.diff(DateTime.utc_now(), recording.updated_at) >= @settle_seconds do
      case RecordingStorage.size(recording) do
        {:ok, bytes} when bytes > 0 ->
          update_pending(recording, %{status: :ready, size_bytes: bytes})

        {:error, :unavailable} ->
          :ok

        _ ->
          update_pending(recording, %{status: :failed})
      end
    end
  end

  defp apply_info(recording, %{id: id} = info) when is_binary(id) do
    fields =
      case info.status do
        :complete -> file_fields(info)
        :unknown -> nil
        status -> %{status: status}
      end

    if fields, do: update_pending(recording, Map.put(fields, :egress_id, id))
  end

  defp apply_info(_recording, _info), do: :ok

  defp file_fields(info) do
    with [%{"size" => size} = file] <- info.files,
         {bytes, ""} when bytes > 0 <- Integer.parse(to_string(size)),
         {nanoseconds, ""} <- Integer.parse(to_string(Map.get(file, "duration", 0))) do
      %{status: :ready, size_bytes: bytes, duration_seconds: div(nanoseconds, 1_000_000_000)}
    else
      _ -> %{status: :failed}
    end
  end

  defp update_pending(recording, fields) do
    {:ok, changed} =
      Repo.transaction(fn ->
        current = Repo.one(from r in Recording, where: r.id == ^recording.id, lock: "FOR UPDATE")

        if current && current.status in @pending &&
             forward_status?(current.status, fields.status) do
          changeset = Ecto.Changeset.change(current, fields)
          if changeset.changes != %{}, do: Repo.update!(changeset)
        end
      end)

    if changed do
      # The recorder's WebRTC participant can linger after the file is saved.
      # Removing it makes LiveKit clear the in-call indicator on all clients.
      if changed.status in [:ready, :failed] and is_binary(changed.egress_id) do
        LiveKit.remove_participant(room_name(changed), changed.egress_id)
      end

      broadcast(changed.workspace_id)
    end

    :ok
  end

  defp forward_status?(:processing, status) when status in [:starting, :recording], do: false
  defp forward_status?(:recording, :starting), do: false
  defp forward_status?(_current, _status), do: true

  defp room_name(recording), do: Meeting.room_name(%Meeting{id: recording.meeting_id})

  defp broadcast(nil), do: :ok
  defp broadcast(id), do: Phoenix.PubSub.broadcast(Devloom.PubSub, topic(id), :recordings_changed)
  defp topic(id), do: "workspace:#{id}:recordings"
end
