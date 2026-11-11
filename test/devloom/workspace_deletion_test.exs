defmodule Devloom.WorkspaceDeletionTest do
  use Devloom.DataCase

  import Devloom.AccountsFixtures

  alias Devloom.Accounts.{Scope, User}
  alias Devloom.Boards.{Board, Column, WorkItem}
  alias Devloom.Chat.Message, as: TeamMessage
  alias Devloom.DirectMessages.{Conversation, Message}
  alias Devloom.Workspaces.{Invitation, Membership, Workspace}
  alias Devloom.{Boards, Chat, DirectMessages, Workspaces}

  setup do
    scope = create_workspace("Team to delete")
    %{scope: scope}
  end

  test "deleting a workspace removes all of its work and chats and preserves other workspaces", %{
    scope: scope
  } do
    peer = join_workspace(scope, user_fixture())
    records = workspace_records(scope, peer)
    {:ok, other_workspace} = Workspaces.create_workspace(scope, %{name: "Team to keep"})
    {:ok, other_scope} = Workspaces.fetch_scope(scope, other_workspace.id)
    other_peer = join_workspace(other_scope, peer.user)
    other_records = workspace_records(other_scope, other_peer)
    memberships = Workspaces.list_members(scope)

    invitations =
      Repo.all(
        from invitation in Invitation, where: invitation.workspace_id == ^scope.workspace.id
      )

    assert :ok = Workspaces.subscribe(peer)
    assert {:ok, deleted} = Workspaces.delete_workspace(scope)
    assert deleted.id == scope.workspace.id
    assert_receive {:workspace_access_changed, workspace_id}
    assert workspace_id == scope.workspace.id

    assert Repo.get(Workspace, scope.workspace.id) == nil
    assert Repo.get(Board, records.board.id) == nil
    assert Repo.get(WorkItem, records.item.id) == nil
    assert Repo.get(TeamMessage, records.team_message.id) == nil
    assert Repo.get(Conversation, records.conversation.id) == nil
    assert Repo.get(Message, records.direct_message.id) == nil
    assert Enum.all?(records.columns, &(Repo.get(Column, &1.id) == nil))
    assert Enum.all?(memberships, &(Repo.get(Membership, &1.id) == nil))
    assert Enum.all?(invitations, &(Repo.get(Invitation, &1.id) == nil))
    assert {:error, :invalid_invitation} = Workspaces.get_invitation(records.invitation_token)

    assert Repo.get!(User, scope.user.id).id == scope.user.id
    assert Repo.get!(User, peer.user.id).id == peer.user.id
    assert Repo.get!(Workspace, other_workspace.id).id == other_workspace.id
    assert Repo.get!(Board, other_records.board.id).id == other_records.board.id
    assert Repo.get!(WorkItem, other_records.item.id).id == other_records.item.id

    assert Repo.get!(TeamMessage, other_records.team_message.id).id ==
             other_records.team_message.id

    assert Repo.get!(Conversation, other_records.conversation.id).id ==
             other_records.conversation.id

    assert Repo.get!(Message, other_records.direct_message.id).id ==
             other_records.direct_message.id

    assert Enum.all?(other_records.columns, &Repo.get(Column, &1.id))
    assert {:ok, _} = Workspaces.get_invitation(other_records.invitation_token)
    assert {:ok, _} = Workspaces.fetch_scope(other_peer, other_workspace.id)
    assert [%Workspace{id: remaining_id}] = Workspaces.list_workspaces(scope)
    assert remaining_id == other_workspace.id
  end

  test "admins can delete a workspace without acquiring owner-only invitation permissions", %{
    scope: scope
  } do
    admin = join_workspace(scope, user_fixture()) |> set_role(:admin)
    assert Workspaces.can_delete_workspace?(admin)
    refute Workspaces.owner?(admin)
    assert [%Workspace{role: :admin}] = Workspaces.list_workspaces(admin)

    assert {:error, :forbidden} =
             Workspaces.create_invitation(admin, %{email: unique_user_email()})

    assert {:error, :forbidden} = Workspaces.remove_member(admin, scope.membership.id)
    assert {:ok, deleted} = Workspaces.delete_workspace(admin)
    assert deleted.id == scope.workspace.id
    assert Repo.get(Workspace, scope.workspace.id) == nil
  end

  test "members, outsiders and forged cached roles cannot delete a workspace", %{scope: scope} do
    member = join_workspace(scope, user_fixture())
    outsider = create_workspace("Outside team")
    assert :ok = Workspaces.subscribe(scope)

    for unauthorized <- [
          member,
          %{member | membership: %{member.membership | role: :owner}},
          %{outsider | workspace: scope.workspace, membership: scope.membership},
          Scope.for_user(scope.user),
          nil
        ] do
      refute Workspaces.can_delete_workspace?(unauthorized)
      assert {:error, :forbidden} = Workspaces.delete_workspace(unauthorized)
      assert Repo.get!(Workspace, scope.workspace.id).id == scope.workspace.id
    end

    refute_received {:workspace_access_changed, _}
    assert Workspaces.can_delete_workspace?(scope)
  end

  test "deletion rechecks persisted roles and removed memberships", %{scope: scope} do
    demoted = join_workspace(scope, user_fixture()) |> set_role(:admin)
    removed = join_workspace(scope, user_fixture()) |> set_role(:admin)
    assert Workspaces.can_delete_workspace?(demoted)
    assert Workspaces.can_delete_workspace?(removed)
    set_role(demoted, :member)
    assert {:ok, _} = Workspaces.remove_member(scope, removed.membership.id)

    for stale <- [demoted, removed] do
      refute Workspaces.can_delete_workspace?(stale)
      assert {:error, :forbidden} = Workspaces.delete_workspace(stale)
    end

    assert Repo.get!(Workspace, scope.workspace.id).id == scope.workspace.id
  end

  test "cached scopes and boards lose access after deletion and repeated deletion is safe", %{
    scope: scope
  } do
    peer = join_workspace(scope, user_fixture())
    records = workspace_records(scope, peer)
    assert {:ok, _} = Workspaces.delete_workspace(scope)

    refute Workspaces.can_delete_workspace?(scope)
    refute Workspaces.authorized_scope?(peer)
    assert {:error, :not_found} = Workspaces.fetch_scope(scope, scope.workspace.id)
    assert {:error, :not_found} = Workspaces.delete_workspace(scope)
    assert {:error, :forbidden} = Workspaces.subscribe(peer)
    assert {:error, :unauthorized} = Boards.create_work_item(scope, %{title: "Deleted team"})

    assert {:error, :unauthorized} =
             Boards.create_work_item(records.board, %{title: "Cached board"})

    assert {:error, :unauthorized} = Chat.create_message(peer, message_attrs("Deleted chat"))
    assert Boards.list_work_items(scope) == []
    assert Chat.list_messages(peer) == []
    assert DirectMessages.list_messages(peer, records.conversation) == []

    assert {:error, :not_found} =
             DirectMessages.create_message(
               peer,
               records.conversation,
               message_attrs("Deleted DM")
             )
  end

  defp create_workspace(name) do
    user_scope = Scope.for_user(user_fixture())
    {:ok, workspace} = Workspaces.create_workspace(user_scope, %{name: name})
    {:ok, scope} = Workspaces.fetch_scope(user_scope, workspace.id)
    scope
  end

  defp join_workspace(owner_scope, user) do
    {:ok, _invitation, token} = Workspaces.create_invitation(owner_scope, %{email: user.email})
    {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    scope
  end

  defp set_role(scope, role) do
    membership = scope.membership |> Ecto.Changeset.change(role: role) |> Repo.update!()
    %{scope | membership: membership}
  end

  defp workspace_records(scope, peer) do
    board = Boards.get_workspace_board!(scope)
    columns = Boards.list_columns(scope)
    {:ok, item} = Boards.create_work_item(scope, %{title: "Workspace task"})
    {:ok, team_message} = Chat.create_message(scope, message_attrs("Team discussion"))
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)

    {:ok, direct_message} =
      DirectMessages.create_message(peer, conversation, message_attrs("Private discussion"))

    {:ok, _invitation, invitation_token} =
      Workspaces.create_invitation(scope, %{email: unique_user_email()})

    %{
      board: board,
      columns: columns,
      item: item,
      team_message: team_message,
      conversation: conversation,
      direct_message: direct_message,
      invitation_token: invitation_token
    }
  end

  defp message_attrs(body), do: %{body: body, client_ref: Ecto.UUID.generate()}
end
