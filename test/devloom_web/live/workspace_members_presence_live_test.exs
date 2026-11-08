defmodule DevloomWeb.WorkspaceMembersPresenceLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Devloom.{WorkspacePresence, Workspaces}
  alias Devloom.Accounts.Scope
  alias Devloom.AccountsFixtures
  alias DevloomWeb.Presence

  setup %{conn: conn} do
    context = setup_workspace(conn)
    member = AccountsFixtures.user_fixture(%{name: "Jamie"})
    {:ok, _invite, token} = Workspaces.create_invitation(context.scope, %{email: member.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(member), token)
    {:ok, member_scope} = Workspaces.fetch_scope(Scope.for_user(member), context.workspace.id)
    Map.merge(context, %{member: member, member_scope: member_scope})
  end

  test "members show live status and a private-message link for other teammates", %{
    conn: conn,
    scope: scope,
    user: user,
    member: member
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{scope.workspace.id}/members")

    assert has_element?(view, "#member-status-#{user.id}[data-online='true']", "Online")
    assert has_element?(view, "#member-status-#{member.id}[data-online='false']", "Offline")

    assert has_element?(
             view,
             "#message-member-#{member.id}[href='/workspaces/#{scope.workspace.id}/chat/direct/#{member.id}']"
           )

    refute has_element?(view, "#message-member-#{user.id}")
  end

  test "a member stays online until their last connected workspace tab closes", %{
    conn: conn,
    scope: scope,
    member: member
  } do
    :ok = WorkspacePresence.subscribe(scope)
    {:ok, directory, _html} = live(conn, ~p"/workspaces/#{scope.workspace.id}/members")
    assert_presence(scope, scope.user.id, :joins)
    member_conn = log_in_user(build_conn(), member)
    {:ok, first, _html} = live(member_conn, ~p"/workspaces/#{scope.workspace.id}/board")
    assert_presence(scope, member.id, :joins)
    assert has_element?(directory, "#member-status-#{member.id}[data-online='true']")

    {:ok, second, _html} =
      live(log_in_user(build_conn(), member), ~p"/workspaces/#{scope.workspace.id}/board")

    assert_presence(scope, member.id, :joins)
    stop_view(first)
    assert_presence(scope, member.id, :leaves)
    assert has_element?(directory, "#member-status-#{member.id}[data-online='true']")

    stop_view(second)
    assert_presence(scope, member.id, :leaves)
    assert has_element?(directory, "#member-status-#{member.id}[data-online='false']")
  end

  test "removing a member untracks their connected view immediately", %{
    conn: conn,
    scope: scope,
    member: member,
    member_scope: member_scope
  } do
    :ok = WorkspacePresence.subscribe(scope)
    {:ok, directory, _html} = live(conn, ~p"/workspaces/#{scope.workspace.id}/members")
    assert_presence(scope, scope.user.id, :joins)

    {:ok, member_board, _html} =
      live(log_in_user(build_conn(), member), ~p"/workspaces/#{scope.workspace.id}/board")

    assert_presence(scope, member.id, :joins)
    assert {:ok, _workspace} = Workspaces.remove_member(scope, member_scope.membership.id)
    assert_redirect(member_board, ~p"/workspaces")
    assert_presence(scope, member.id, :leaves)

    refute has_element?(directory, "#member-#{member_scope.membership.id}")
    refute Map.has_key?(Presence.list(WorkspacePresence.topic(scope)), to_string(member.id))
  end

  defp stop_view(view) do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  defp assert_presence(scope, user_id, direction) do
    topic = WorkspacePresence.topic(scope)
    key = to_string(user_id)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "presence_diff",
                     payload: %{^direction => %{^key => _presence}}
                   },
                   1_000

    for pid <- Presence.fetchers_pids() do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end
  end
end
