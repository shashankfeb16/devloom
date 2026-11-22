defmodule Devloom.Meetings do
  @moduledoc "Workspace meeting lifecycle and LiveKit authorization."
  import Ecto.Query

  alias Devloom.Accounts.{Scope, UserToken}
  alias Devloom.Meetings.{LiveKit, Meeting, Recordings}
  alias Devloom.Workspaces.{Membership, Workspace}
  alias Devloom.{Repo, Workspaces}

  defdelegate configured?(), to: LiveKit

  def active(%Scope{workspace: %Workspace{id: id}} = scope) do
    if configured?() and Workspaces.authorized_scope?(scope), do: active_in(id)
  end

  def join(%Scope{} = scope, action, session_token)
      when is_binary(session_token) and byte_size(session_token) == 32 do
    with {:ok, {meeting, credentials}} <-
           with_workspace(scope, fn scope ->
             session = Repo.one(UserToken.active_token_query(session_token))
             unless session && session.user_id == scope.user.id, do: Repo.rollback(:forbidden)

             meeting = meeting_to_join(scope, action)
             identity = "session-#{session.id}"
             {meeting, LiveKit.join_credentials(Meeting.room_name(meeting), scope.user, identity)}
           end) do
      if action == :start, do: broadcast(meeting.workspace_id)
      {:ok, meeting, credentials}
    end
  end

  def join(_scope, _action, _session_token), do: {:error, :forbidden}

  def end_meeting(%Scope{} = scope, id) do
    with {:ok, meeting} <- with_control(scope, id, fn _scope, meeting -> close_room(meeting) end) do
      broadcast(meeting.workspace_id)
      {:ok, meeting}
    end
  end

  @doc false
  def with_control(scope, id, fun) do
    with_workspace(scope, fn scope ->
      meeting = active_in(scope.workspace.id)
      unless meeting && meeting.id == id, do: Repo.rollback(:no_meeting)
      unless can_end?(scope, meeting), do: Repo.rollback(:forbidden)
      fun.(scope, meeting)
    end)
  end

  def can_end?(%Scope{user: user, membership: membership}, %Meeting{host_id: host}) do
    user.id == host or membership.role == :owner
  end

  def subscribe(%Scope{workspace: %Workspace{id: id}}),
    do: Phoenix.PubSub.subscribe(Devloom.PubSub, topic(id))

  def reconcile(workspace_id \\ nil) do
    query = Meeting

    query =
      if workspace_id,
        do: from(meeting in query, where: meeting.workspace_id == ^workspace_id),
        else: query

    meetings = Repo.all(query)

    if meetings != [] do
      with {:ok, rooms} <- LiveKit.list_rooms(Enum.map(meetings, &Meeting.room_name/1)) do
        names = MapSet.new(rooms, &Map.fetch!(&1, "name"))
        Enum.each(meetings, &reconcile_meeting(&1, names))
      end
    end
  end

  defp reconcile_meeting(%Meeting{workspace_id: nil} = meeting, _names) do
    case LiveKit.delete_room(Meeting.room_name(meeting)) do
      {:error, :unavailable} -> :ok
      _ -> Repo.delete(meeting, allow_stale: true)
    end
  end

  defp reconcile_meeting(meeting, names) do
    room = Meeting.room_name(meeting)

    if MapSet.member?(names, room) do
      remove_unauthorized_participants(room, meeting.workspace_id)
    else
      {count, _} =
        from(m in Meeting, where: m.id == ^meeting.id)
        |> Repo.delete_all()

      if count > 0, do: broadcast(meeting.workspace_id)
    end
  end

  defp remove_unauthorized_participants(room, workspace_id) do
    with {:ok, participants} <- LiveKit.list_participants(room) do
      ids = Enum.flat_map(participants, &session_id(&1["identity"]))

      authorized =
        UserToken.active_sessions()
        |> join(:inner, [session], member in Membership, on: member.user_id == session.user_id)
        |> where([session, member], session.id in ^ids and member.workspace_id == ^workspace_id)
        |> select([session, _], session.id)
        |> Repo.all()
        |> MapSet.new(&"session-#{&1}")

      for %{"identity" => identity} = participant <- participants,
          not recorder?(participant),
          not LiveKit.transcriber?(participant),
          not MapSet.member?(authorized, identity) do
        LiveKit.remove_participant(room, identity)
      end
    end
  end

  defp recorder?(participant) do
    participant["kind"] in ["EGRESS", 2] or
      get_in(participant, ["permission", "recorder"]) == true
  end

  defp session_id("session-" <> id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 -> [number]
      _ -> []
    end
  end

  defp session_id(_), do: []

  defp meeting_to_join(scope, action) do
    id = scope.workspace.id
    meeting = active_in(id)

    case {action, meeting} do
      {:start, nil} ->
        meeting = Repo.insert!(%Meeting{workspace_id: id, host_id: scope.user.id})

        case LiveKit.create_room(Meeting.room_name(meeting)) do
          {:ok, _} -> meeting
          {:error, _} -> Repo.rollback(:unavailable)
        end

      {:start, %Meeting{}} ->
        meeting

      {{:join, id}, %Meeting{id: id}} ->
        meeting

      _ ->
        Repo.rollback(:no_meeting)
    end
  end

  defp close_room(meeting) do
    Recordings.stop_before_room_close(meeting)

    case LiveKit.delete_room(Meeting.room_name(meeting)) do
      {:error, :unavailable} -> Repo.rollback(:unavailable)
      _ -> Repo.delete!(meeting, allow_stale: true)
    end
  end

  defp active_in(id) do
    Repo.get_by(Meeting, workspace_id: id)
  end

  defp with_workspace(%Scope{workspace: %Workspace{id: id}} = scope, fun) do
    if configured?() do
      Repo.transaction(fn ->
        Repo.one(from workspace in Workspace, where: workspace.id == ^id, lock: "FOR UPDATE") ||
          Repo.rollback(:forbidden)

        case Workspaces.fetch_scope(scope, id) do
          {:ok, scope} -> fun.(scope)
          {:error, _} -> Repo.rollback(:forbidden)
        end
      end)
    else
      {:error, :disabled}
    end
  end

  defp with_workspace(_scope, _fun), do: {:error, :forbidden}

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Devloom.PubSub, topic(id), {:meeting_changed, id})

  defp topic(id), do: "workspace:#{id}:meetings"
end
