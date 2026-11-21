defmodule DevloomWeb.RecordingsLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Devloom.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Devloom.Accounts.Scope
  alias Devloom.Meetings
  alias Devloom.Meetings.{LiveKit, Meeting, Recording, Recordings, RecordingStorage}
  alias Devloom.Workspaces

  setup %{conn: conn} do
    for {module, options} <- [
          {LiveKit,
           [
             url: "wss://meetings.example.com",
             api_url: "https://meetings.example.com",
             api_key: "recordings-test",
             api_secret: "recordings-test-secret"
           ]},
          {RecordingStorage,
           [
             bucket: "meeting-recordings",
             region: "us-east-1",
             endpoint: "https://storage.example.com",
             access_key_id: "test-access-key",
             secret_access_key: "test-secret-key"
           ]}
        ] do
      previous = Application.get_env(:devloom, module)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:devloom, module, previous),
          else: Application.delete_env(:devloom, module)
      end)

      Application.put_env(
        :devloom,
        module,
        options ++ [request_options: [plug: {Req.Test, module}]]
      )
    end

    Req.Test.set_req_test_to_shared()
    setup_workspace(conn)
  end

  test "a host records and stops a meeting, then members can play and download it", %{
    conn: owner_conn,
    scope: owner,
    workspace: workspace
  } do
    host_conn = invite_member(owner)
    member_conn = invite_member(owner)
    start_room_stub()
    meeting_path = "/workspaces/#{workspace.id}/meetings"
    {:ok, host, _} = live(host_conn, meeting_path)
    {:ok, member, _} = live(member_conn, meeting_path)
    {:ok, library, _} = live(owner_conn, library_path(workspace))

    render_hook(host, "enter_meeting", %{action: "start"})
    assert_reply host, %{status: "ok", meeting_id: meeting_id}
    room = Meeting.room_name(%Meeting{id: meeting_id})
    assert has_element?(host, "#meeting-room[data-can-record='true']")
    assert has_element?(member, "#meeting-room[data-can-record='false']")

    render_hook(member, "recording_control", %{id: meeting_id, action: "start"})
    assert_reply member, %{status: "error"}

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.Egress", "StartEgress"]
      assert ["Bearer " <> token] = get_req_header(request, "authorization")
      [_, claims, _] = String.split(token, ".")

      assert %{"video" => %{"roomRecord" => true}} =
               claims |> Base.url_decode64!(padding: false) |> Jason.decode!()

      {:ok, body, request} = read_body(request)

      assert %{
               "room_name" => ^room,
               "outputs" => [%{"file" => %{"filepath" => filepath, "file_type" => "MP4"}}],
               "storage" => %{"s3" => %{"bucket" => "meeting-recordings"}}
             } = Jason.decode!(body)

      assert String.starts_with?(filepath, "recordings/")
      Req.Test.json(request, %{"egress_id" => "EG_test", "status" => "EGRESS_ACTIVE"})
    end)

    render_hook(host, "recording_control", %{id: meeting_id, action: "start"})
    assert_reply host, %{status: "ok"}
    assert has_element?(member, "#meeting-room[data-recording-status='recording']")

    [recording] = Recordings.list(owner)
    assert recording.status == :recording

    assert recording.started_by_id ==
             get_session(host_conn, :user_token)
             |> Devloom.Accounts.get_user_by_session_token()
             |> Map.fetch!(:id)

    assert has_element?(library, "#recordings-#{recording.id} [data-status=recording]")

    render_hook(host, "recording_control", %{id: meeting_id, action: "start"})
    assert_reply host, %{status: "error"}

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.Egress", "StopEgress"]
      assert {:ok, ~s({"egress_id":"EG_test"}), request} = read_body(request)
      Req.Test.json(request, %{egressId: "EG_test", status: "EGRESS_ENDING"})
    end)

    render_hook(host, "recording_control", %{id: meeting_id, action: "stop"})
    assert_reply host, %{status: "ok"}
    assert has_element?(library, "#recordings-#{recording.id} [data-status=processing]")

    start_room_stub()
    assert {:ok, _} = Meetings.end_meeting(owner, meeting_id)

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.Egress", "ListEgress"]

      Req.Test.json(request, %{
        items: [
          %{
            egress_id: "EG_test",
            status: "EGRESS_COMPLETE",
            file_results: [%{size: "2450000", duration: "65000000000"}]
          }
        ]
      })
    end)

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.RoomService", "RemoveParticipant"]
      {:ok, body, request} = read_body(request)
      assert %{"room" => ^room, "identity" => "EG_test"} = Jason.decode!(body)
      Req.Test.json(request, %{})
    end)

    Recordings.reconcile()
    assert Req.Test.verify!(LiveKit)

    assert {:ok, %{status: :ready, duration_seconds: 65, size_bytes: 2_450_000}} =
             Recordings.fetch(owner, recording.id)

    {:ok, member_library, _} = live(member_conn, library_path(workspace))
    assert has_element?(member_library, "#nav-recordings[aria-current=page]")
    refute has_element?(member_library, "#delete-recording-#{recording.id}")
    member_library |> element("#play-recording-#{recording.id}") |> render_click()
    assert_patch(member_library, "#{library_path(workspace)}/#{recording.id}")

    assert has_element?(
             member_library,
             "#recording-video[src='#{video_path(workspace, recording)}']"
           )

    assert has_element?(member_library, "#download-recording")

    response =
      member_conn
      |> put_req_header("accept", "video/mp4, video/*;q=0.9, */*;q=0.5")
      |> get(video_path(workspace, recording))

    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    url = response |> redirected_to() |> URI.parse()
    assert url.host == "storage.example.com"
    key = Recording.object_key(recording)
    assert url.path == "/meeting-recordings/#{key}"

    assert %{"X-Amz-Signature" => _, "response-content-disposition" => "inline"} =
             URI.decode_query(url.query)

    url =
      member_conn
      |> get(video_path(workspace, recording) <> "?download=1")
      |> redirected_to()
      |> URI.parse()

    assert %{"response-content-disposition" => "attachment;" <> _} = URI.decode_query(url.query)
  end

  test "an approved stop finishes after the caller leaves the meeting page", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    start_room_stub()
    assert {:ok, meeting, _} = Meetings.join(owner, :start, get_session(conn, :user_token))

    recording =
      Devloom.Repo.insert!(%Recording{
        workspace_id: workspace.id,
        meeting_id: meeting.id,
        egress_id: "EG_disconnect",
        status: :recording
      })

    :ok = Recordings.subscribe(owner)
    test = self()

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.Egress", "StopEgress"]
      send(test, {:stop_requested, self()})

      receive do
        :finish_stop ->
          Req.Test.json(request, %{egress_id: "EG_disconnect", status: "EGRESS_ENDING"})
      after
        2_000 -> flunk("Timed out waiting to complete the recording stop")
      end
    end)

    caller = start_supervised!({Task, fn -> Recordings.stop(owner, meeting.id) end})
    monitor = Process.monitor(caller)
    assert_receive {:stop_requested, worker}, 2_000
    Process.exit(caller, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :shutdown}
    send(worker, :finish_stop)

    assert_receive :recordings_changed, 2_000
    assert {:ok, %{status: :processing}} = Recordings.fetch(owner, recording.id)
  end

  test "only the owner can delete a recording and workspace IDs cannot be crossed", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    recording = insert_recording(workspace)
    other = setup_workspace(build_conn())
    member_conn = invite_member(owner)
    assert response(get(other.conn, video_path(workspace, recording)), 404)
    assert response(get(other.conn, video_path(other.workspace, recording)), 404)
    assert redirected_to(get(build_conn(), video_path(workspace, recording))) == "/users/log_in"

    {:ok, member_library, _} = live(member_conn, library_path(workspace))
    render_click(member_library, "delete_recording", %{id: recording.id})
    {:ok, other_library, _} = live(other.conn, library_path(other.workspace))
    render_click(other_library, "delete_recording", %{id: recording.id})
    assert {:ok, _} = Recordings.fetch(owner, recording.id)

    {:ok, owner_library, _} = live(conn, library_path(workspace))
    Req.Test.stub(RecordingStorage, &send_resp(&1, 503, "Unavailable"))
    owner_library |> element("#delete-recording-#{recording.id}") |> render_click()
    assert has_element?(owner_library, "#recordings-#{recording.id}")

    Req.Test.expect(RecordingStorage, fn request ->
      assert request.method == "DELETE"
      assert request.request_path == "/meeting-recordings/#{Recording.object_key(recording)}"
      assert [auth] = get_req_header(request, "authorization")
      assert String.starts_with?(auth, "AWS4-HMAC-SHA256 ")
      send_resp(request, 204, "")
    end)

    owner_library |> element("#delete-recording-#{recording.id}") |> render_click()
    refute has_element?(member_library, "#recordings-#{recording.id}")
    assert {:error, :not_found} = Recordings.fetch(owner, recording.id)
  end

  test "reconciliation recovers an accepted start after the HTTP response is lost", %{
    conn: conn,
    scope: owner
  } do
    start_room_stub()
    assert {:ok, meeting, _} = Meetings.join(owner, :start, get_session(conn, :user_token))
    Req.Test.stub(LiveKit, &send_resp(&1, 504, "Timeout"))
    assert {:error, :recording_start_unknown} = Recordings.start(owner, meeting.id)
    assert {:error, :recording_in_progress} = Recordings.start(owner, meeting.id)
    [recording] = Recordings.list(owner)
    key = Recording.object_key(recording)

    Req.Test.stub(LiveKit, fn request ->
      Req.Test.json(request, %{
        items: [
          %{egress_id: "EG_other", egress: %{outputs: [%{file: %{filepath: "unrelated.mp4"}}]}},
          %{
            egress_id: "EG_recovered",
            status: "EGRESS_ACTIVE",
            egress: %{outputs: [%{file: %{filepath: key}}]}
          }
        ]
      })
    end)

    Recordings.reconcile()

    assert {:ok, %{status: :recording, egress_id: "EG_recovered"}} =
             Recordings.fetch(owner, recording.id)

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.Egress", "StopEgress"]
      Req.Test.json(request, %{egress_id: "EG_recovered", status: "EGRESS_ENDING"})
    end)

    Req.Test.expect(LiveKit, fn request ->
      assert request.path_info == ["twirp", "livekit.RoomService", "DeleteRoom"]
      Req.Test.json(request, %{})
    end)

    assert {:ok, _} = Meetings.end_meeting(owner, meeting.id)
    assert Req.Test.verify!(LiveKit)
  end

  test "deleting a workspace revokes video access and the worker cleans up storage", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    recording = insert_recording(workspace)
    assert {:ok, _} = Workspaces.delete_workspace(owner)
    assert response(get(conn, video_path(workspace, recording)), 404)

    Req.Test.expect(RecordingStorage, fn request ->
      assert request.method == "DELETE"
      assert request.request_path == "/meeting-recordings/#{Recording.object_key(recording)}"
      send_resp(request, 204, "")
    end)

    Recordings.reconcile()
    refute Devloom.Repo.get(Recording, recording.id)
  end

  defp start_room_stub, do: Req.Test.stub(LiveKit, &Req.Test.json(&1, %{}))

  defp insert_recording(workspace) do
    Devloom.Repo.insert!(%Recording{
      workspace_id: workspace.id,
      meeting_id: Ecto.UUID.generate(),
      status: :ready
    })
  end

  defp invite_member(owner) do
    user = user_fixture()
    {:ok, _invite, token} = Workspaces.create_invitation(owner, %{email: user.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    log_in_user(build_conn(), user)
  end

  defp library_path(workspace), do: "/workspaces/#{workspace.id}/recordings"
  defp video_path(workspace, recording), do: "#{library_path(workspace)}/#{recording.id}/video"
end
