defmodule DevloomWeb.MeetingLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Devloom.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Devloom.Accounts.Scope
  alias Devloom.Meetings
  alias Devloom.Meetings.{LiveKit, Meeting, Transcripts}
  alias Devloom.Workspaces

  setup %{conn: conn} do
    config = Application.fetch_env(:devloom, LiveKit)

    on_exit(fn ->
      case config do
        {:ok, config} -> Application.put_env(:devloom, LiveKit, config)
        :error -> Application.delete_env(:devloom, LiveKit)
      end
    end)

    Application.put_env(:devloom, LiveKit,
      url: "wss://meetings.example.com",
      api_url: "https://meetings.example.com",
      api_key: "meeting-tests",
      api_secret: "meeting-tests-secret",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.set_req_test_to_shared()
    setup_workspace(conn)
  end

  test "requires a signed-in workspace member", %{conn: conn, workspace: workspace} do
    assert redirected_to(get(build_conn(), path(workspace))) == "/users/log_in"
    other = setup_workspace(build_conn())

    assert {:error, {:live_redirect, %{to: "/workspaces"}}} =
             live(conn, path(other.workspace))
  end

  test "shows an unavailable state when the media server is unconfigured", %{
    conn: conn,
    workspace: workspace
  } do
    Application.delete_env(:devloom, LiveKit)
    {:ok, view, _} = live(conn, path(workspace))
    assert has_element?(view, "#meetings-unavailable")
    refute has_element?(view, "#enter-meeting")
  end

  test "members see the same room, with a scoped token, and the host can close it", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    Req.Test.stub(__MODULE__, fn request ->
      case request.path_info do
        ["twirp", "livekit.RoomService", method] when method in ["CreateRoom", "DeleteRoom"] ->
          Req.Test.json(request, %{})
      end
    end)

    member_conn = invite_member(owner)
    {:ok, host, _} = live(conn, path(workspace))
    {:ok, member, _} = live(member_conn, path(workspace))
    {:ok, board, _} = live(member_conn, "/workspaces/#{workspace.id}/board")

    assert has_element?(host, "#nav-meetings[aria-current='page']")
    assert has_element?(host, "#mobile-nav-meetings")
    render_hook(host, "enter_meeting", %{action: "start"})
    assert_reply host, %{status: "ok", meeting_id: id, token: token}
    assert has_element?(member, ~s(#meeting-room[data-meeting-id="#{id}"]))
    assert has_element?(board, "#workspace-meeting-banner a")

    assert has_element?(
             host,
             "#meeting-room[data-can-record=true][data-recordings-configured=false]"
           )

    assert has_element?(member, "#meeting-room[data-can-record=false]")

    render_hook(host, "recording_control", %{id: id, action: "start"})

    assert_reply host, %{
      status: "error",
      message: "Recording is unavailable on this Devloom server."
    }

    [_, payload, _] = String.split(token, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["video"]["room"] == Meeting.room_name(%Meeting{id: id})
    assert claims["video"]["roomJoin"]
    refute claims["video"]["roomAdmin"]

    render_hook(member, "enter_meeting", %{action: "start"})
    assert_reply member, %{status: "ok", meeting_id: ^id}
    render_hook(member, "enter_meeting", %{action: "join", meeting_id: Ecto.UUID.generate()})
    assert_reply member, %{status: "error"}
    refute has_element?(member, "#end-meeting")
    render_click(member, "end_meeting", %{id: id})
    assert Meetings.active(owner).id == id

    host |> element("#end-meeting") |> render_click()
    refute has_element?(member, "#meeting-room[data-meeting-id]")
    refute has_element?(board, "#workspace-meeting-banner")
    assert Meetings.active(owner) == nil
  end

  test "only a connected host or workspace owner can start a room transcript", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    Application.put_env(:devloom, Transcripts,
      url: "https://transcriber.example.com",
      secret: "transcription-test",
      request_options: [plug: {Req.Test, :transcription}]
    )

    on_exit(fn -> Application.delete_env(:devloom, Transcripts) end)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))

    {:ok, host, _} = live(conn, path(workspace))
    {:ok, member, _} = live(invite_member(owner), path(workspace))
    render_hook(host, "enter_meeting", %{action: "start"})
    assert_reply host, %{status: "ok", meeting_id: id, token: join_token}
    room = Meeting.room_name(%Meeting{id: id})

    assert has_element?(
             host,
             "#meeting-room[data-can-transcribe=true][data-transcripts-configured=true]"
           )

    assert has_element?(member, "#meeting-room[data-can-transcribe=false]")

    render_hook(member, "transcript_control", %{action: "start", id: id})
    assert_reply member, %{status: "error"}

    render_hook(host, "transcript_control", %{action: "start", id: id})

    assert_reply host, %{
      status: "error",
      message: "Join the call before starting the transcript."
    }

    Req.Test.stub(__MODULE__, fn request ->
      assert request.path_info == ["twirp", "livekit.RoomService", "ListParticipants"]
      Req.Test.json(request, %{participants: [%{identity: token_claims(join_token)["sub"]}]})
    end)

    Req.Test.expect(:transcription, fn request ->
      assert request.path_info == ["rooms", room, "start"]
      assert get_req_header(request, "authorization") == ["Bearer transcription-test"]
      {:ok, body, request} = read_body(request)
      assert %{"token" => token} = Jason.decode!(body)

      assert %{
               "sub" => "devloom-transcriber",
               "kind" => "agent",
               "video" => %{
                 "room" => ^room,
                 "roomJoin" => true,
                 "canSubscribe" => true,
                 "canPublishData" => true,
                 "canPublish" => false
               }
             } = token_claims(token)

      Req.Test.json(request, %{active: true})
    end)

    render_hook(host, "transcript_control", %{action: "start", id: id})
    assert_reply host, %{status: "ok"}

    render_hook(member, "transcript_control", %{action: "stop", id: id})
    assert_reply member, %{status: "error"}

    Req.Test.expect(:transcription, fn request ->
      assert request.path_info == ["rooms", room, "stop"]
      Req.Test.json(request, %{active: false})
    end)

    render_hook(host, "transcript_control", %{action: "stop", id: id})
    assert_reply host, %{status: "ok"}
    assert Req.Test.verify!(:transcription)
  end

  test "failed media server requests can be retried without leaving duplicate meetings", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    Req.Test.stub(__MODULE__, fn request -> Plug.Conn.send_resp(request, 503, "Unavailable") end)
    {:ok, view, _} = live(conn, path(workspace))
    render_hook(view, "enter_meeting", %{action: "start"})
    assert_reply view, %{status: "error"}
    assert Meetings.active(owner) == nil

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))
    render_hook(view, "enter_meeting", %{action: "start"})
    assert_reply view, %{status: "ok", meeting_id: id}
    Req.Test.stub(__MODULE__, fn request -> Plug.Conn.send_resp(request, 503, "Unavailable") end)
    view |> element("#end-meeting") |> render_click()
    assert Meetings.active(owner).id == id
  end

  test "a removed workspace member loses page and media access", %{
    conn: conn,
    scope: owner,
    workspace: workspace
  } do
    test_process = self()
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))
    member_conn = invite_member(owner)
    {:ok, member, _} = live(member_conn, path(workspace))
    {:ok, meeting, _} = Meetings.join(owner, :start, get_session(conn, :user_token))
    render_hook(member, "enter_meeting", %{action: "join", meeting_id: meeting.id})
    assert_reply member, %{status: "ok", token: token}
    [_, payload, _] = String.split(token, ".")

    identity =
      payload |> Base.url_decode64!(padding: false) |> Jason.decode!() |> Map.fetch!("sub")

    room = Meeting.room_name(meeting)

    Req.Test.stub(__MODULE__, fn request ->
      case List.last(request.path_info) do
        "ListRooms" ->
          Req.Test.json(request, %{rooms: [%{name: room}]})

        "ListParticipants" ->
          Req.Test.json(request, %{
            participants: [
              %{identity: identity},
              %{identity: "recording-worker", kind: "EGRESS"},
              %{identity: "devloom-transcriber", kind: "AGENT"}
            ]
          })

        "RemoveParticipant" ->
          {:ok, body, request} = Plug.Conn.read_body(request)
          send(test_process, {:removed, Jason.decode!(body)})
          Req.Test.json(request, %{})
      end
    end)

    membership = Enum.find(Workspaces.list_members(owner), &(&1.role == :member))
    assert {:ok, _} = Workspaces.remove_member(owner, membership.id)
    assert_redirect(member, "/workspaces")
    Meetings.reconcile(workspace.id)
    assert_receive {:removed, %{"room" => ^room, "identity" => ^identity}}
    refute_received {:removed, %{"identity" => "recording-worker"}}
    refute_received {:removed, %{"identity" => "devloom-transcriber"}}
  end

  defp token_claims(token) do
    [_, payload, _] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp invite_member(owner) do
    user = user_fixture()
    {:ok, _invite, token} = Workspaces.create_invitation(owner, %{email: user.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    log_in_user(build_conn(), user)
  end

  defp path(workspace), do: "/workspaces/#{workspace.id}/meetings"
end
