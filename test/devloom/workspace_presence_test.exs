defmodule Devloom.WorkspacePresenceTest do
  use Devloom.DataCase, async: false

  alias Devloom.{WorkspacePresence, Workspaces}
  alias Devloom.Accounts.Scope
  alias Devloom.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, workspace} = Workspaces.create_workspace(Scope.for_user(user), %{name: "Presence team"})
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    %{user: user, scope: scope}
  end

  test "multiple connections count once until the final process disconnects", %{scope: scope} do
    :ok = WorkspacePresence.subscribe(scope)
    first = start_supervised!({Agent, fn -> nil end}, id: :first_connection)
    second = start_supervised!({Agent, fn -> nil end}, id: :second_connection)

    assert {:ok, _ref} = WorkspacePresence.track(scope, first)
    assert_presence(scope, :joins)
    assert {:ok, _ref} = WorkspacePresence.track(scope, second)
    assert_presence(scope, :joins)
    assert WorkspacePresence.online_user_ids(scope) == MapSet.new([scope.user.id])

    stop_supervised!(:first_connection)
    assert_presence(scope, :leaves)
    assert WorkspacePresence.online_user_ids(scope) == MapSet.new([scope.user.id])

    stop_supervised!(:second_connection)
    assert_presence(scope, :leaves)
    assert WorkspacePresence.online_user_ids(scope) == MapSet.new()
  end

  test "online status is specific to the currently connected workspace", %{scope: scope} do
    {:ok, another} =
      Workspaces.create_workspace(Scope.for_user(scope.user), %{name: "Other team"})

    {:ok, other_scope} = Workspaces.fetch_scope(Scope.for_user(scope.user), another.id)
    connection = start_supervised!({Agent, fn -> nil end})

    assert {:ok, _ref} = WorkspacePresence.track(scope, connection)
    assert WorkspacePresence.online_user_ids(scope) == MapSet.new([scope.user.id])
    assert WorkspacePresence.online_user_ids(other_scope) == MapSet.new()
  end

  test "an outsider cannot publish or read a workspace's online members", %{scope: scope} do
    outsider = AccountsFixtures.user_fixture()

    forged_scope = %{
      Scope.for_user(outsider)
      | workspace: scope.workspace,
        membership: scope.membership
    }

    assert WorkspacePresence.track(forged_scope) == {:error, :unauthorized}
    assert WorkspacePresence.subscribe(forged_scope) == {:error, :unauthorized}
    assert WorkspacePresence.online_user_ids(forged_scope) == MapSet.new()
    assert WorkspacePresence.track(nil) == {:error, :unauthorized}
    assert WorkspacePresence.online_user_ids(nil) == MapSet.new()
  end

  test "removed members are filtered even if a previous connection has not stopped", %{
    scope: owner
  } do
    member = AccountsFixtures.user_fixture()
    {:ok, _invite, token} = Workspaces.create_invitation(owner, %{email: member.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(member), token)
    {:ok, member_scope} = Workspaces.fetch_scope(Scope.for_user(member), owner.workspace.id)
    connection = start_supervised!({Agent, fn -> nil end})

    assert {:ok, _ref} = WorkspacePresence.track(member_scope, connection)
    assert MapSet.member?(WorkspacePresence.online_user_ids(owner), member.id)
    assert {:ok, _workspace} = Workspaces.remove_member(owner, member_scope.membership.id)

    refute MapSet.member?(WorkspacePresence.online_user_ids(owner), member.id)
    assert WorkspacePresence.online_user_ids(member_scope) == MapSet.new()
    assert WorkspacePresence.track(member_scope) == {:error, :unauthorized}
    assert WorkspacePresence.untrack(member_scope, connection) == :ok
  end

  defp assert_presence(scope, direction) do
    topic = WorkspacePresence.topic(scope)
    user_id = to_string(scope.user.id)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "presence_diff",
                     payload: %{^direction => %{^user_id => _presence}}
                   },
                   1_000
  end
end
