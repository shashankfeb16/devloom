defmodule Devloom.WorkspacesTest do
  use Devloom.DataCase

  import Devloom.AccountsFixtures

  alias Devloom.Accounts.Scope
  alias Devloom.{Boards, Chat, Workspaces}
  alias Devloom.Workspaces.{Invitation, Membership, Workspace}

  setup do
    owner = user_fixture(%{name: "Workspace owner"})
    scope = Scope.for_user(owner)
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "  Product team  "})
    {:ok, scope} = Workspaces.fetch_scope(scope, workspace.id)
    %{owner: owner, scope: scope, workspace: workspace}
  end

  test "creating a workspace atomically creates its owner and empty board", %{scope: scope} do
    assert scope.workspace.name == "Product team"
    assert scope.membership.role == :owner
    assert [%Workspace{role: :owner, member_count: 1}] = Workspaces.list_workspaces(scope)
    assert [%Membership{user: %{id: user_id}, role: :owner}] = Workspaces.list_members(scope)
    assert user_id == scope.user.id

    board = Boards.get_workspace_board!(scope)
    assert board.workspace_id == scope.workspace.id
    assert length(Boards.list_columns(scope)) == 5
    assert Boards.list_work_items(scope) == []
    assert Chat.list_messages(scope) == []

    assert {:error, changeset} = Workspaces.create_workspace(scope, %{name: " "})
    assert errors_on(changeset).name == ["can't be blank"]
    assert length(Workspaces.list_workspaces(scope)) == 1
    assert {:error, :forbidden} = Workspaces.create_workspace(nil, %{name: "No account"})
  end

  test "tasks, columns, messages, and subscriptions stay within workspace membership", %{
    scope: scope
  } do
    other = create_scope("Other team")
    {:ok, item} = Boards.create_work_item(other, %{title: "Private task"})
    {:ok, message} = Chat.create_message(other, message_attrs("Private conversation"))
    other_column = hd(Boards.list_columns(other))

    assert Boards.get_work_item(scope, item.id) == nil
    assert Boards.get_column(scope, other_column.id) == nil
    assert {:error, :not_found} = Boards.update_work_item(scope, item, %{title: "Intrusion"})
    assert {:error, :not_found} = Boards.delete_work_item(scope, item)
    assert {:error, :not_found} = Boards.move_work_item(scope, item.id, "todo")
    assert {:error, :not_found} = Boards.update_column(scope, other_column, %{title: "Intrusion"})
    assert {:error, :not_found} = Boards.delete_column(scope, other_column)
    assert Chat.list_messages(scope) == []

    Chat.subscribe(scope)
    {:ok, _} = Chat.create_message(other, message_attrs("Another private message"))
    refute_received {:message_created, _}

    {:ok, mine} =
      Chat.create_message(
        scope,
        Map.merge(message_attrs("Team update"), %{
          sender_name: "Impersonation",
          user_id: other.user.id
        })
      )

    assert mine.sender_name == scope.user.name
    assert mine.user_id == scope.user.id
    assert mine.board_id != message.board_id
    assert Chat.list_messages(scope) == [mine]
    assert length(Chat.list_messages(other)) == 2

    forged = %{scope | workspace: other.workspace}
    refute Workspaces.authorized_scope?(forged)
    assert Workspaces.list_members(forged) == []
    assert Boards.list_work_items(forged) == []
    assert Chat.list_messages(forged) == []
    assert {:error, :unauthorized} = Boards.create_work_item(forged, %{title: "Intrusion"})
    assert {:error, :unauthorized} = Chat.create_message(forged, message_attrs("Intrusion"))
    assert {:error, :not_found} = Workspaces.fetch_scope(scope, other.workspace.id)
    assert {:error, :not_found} = Workspaces.fetch_scope(scope, "malformed")
  end

  test "invitation secret is hashed, email-bound and single-use", %{scope: scope} do
    member = user_fixture(%{email: "teammate@example.com"})
    outsider = Scope.for_user(user_fixture())

    assert {:ok, invitation, token} =
             Workspaces.create_invitation(scope, %{
               email: "  TEAMMATE@EXAMPLE.COM  ",
               role: "owner"
             })

    assert invitation.email == member.email
    assert byte_size(invitation.token_hash) == 32
    refute invitation.token_hash == token
    assert {:ok, preview} = Workspaces.get_invitation(token)
    assert preview.workspace.id == scope.workspace.id
    assert {:error, :wrong_email} = Workspaces.accept_invitation(outsider, token)
    assert Workspaces.list_workspaces(outsider) == []

    assert {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(member), token)
    assert workspace.id == scope.workspace.id
    assert {:ok, member_scope} = Workspaces.fetch_scope(Scope.for_user(member), workspace.id)
    assert member_scope.membership.role == :member
    assert [%Workspace{role: :member, member_count: 2}] = Workspaces.list_workspaces(member_scope)
    assert {:error, :invalid_invitation} = Workspaces.accept_invitation(member_scope, token)
    assert {:error, :invalid_invitation} = Workspaces.get_invitation(token)
    assert Workspaces.list_pending_invitations(scope) == []
  end

  test "only current owners can invite, revoke or remove members", %{scope: scope} do
    member_scope = join_scope(scope)
    stranger = create_scope("Stranger team")

    assert {:ok, invitation, _token} =
             Workspaces.create_invitation(scope, %{email: unique_user_email()})

    assert {:error, :forbidden} =
             Workspaces.create_invitation(member_scope, %{email: unique_user_email()})

    assert {:error, :forbidden} = Workspaces.revoke_invitation(member_scope, invitation.id)
    assert {:error, :forbidden} = Workspaces.remove_member(member_scope, scope.membership.id)
    assert Workspaces.list_pending_invitations(member_scope) == []
    assert {:error, :not_found} = Workspaces.revoke_invitation(stranger, invitation.id)
    assert {:error, :not_found} = Workspaces.remove_member(stranger, member_scope.membership.id)
    assert {:error, :owner_required} = Workspaces.remove_member(scope, scope.membership.id)
    assert {:error, :not_found} = Workspaces.remove_member(scope, "invalid")

    assert {:error, :already_member} =
             Workspaces.create_invitation(scope, %{email: member_scope.user.email})

    assert {:ok, changeset} = {:ok, Workspaces.change_invitation(%{email: "not an email"})}
    refute changeset.valid?
  end

  test "replacing, revoking and expiring invitations invalidate earlier links", %{scope: scope} do
    email = unique_user_email()
    {:ok, first, first_token} = Workspaces.create_invitation(scope, %{email: email})
    {:ok, second, second_token} = Workspaces.create_invitation(scope, %{email: email})
    assert Repo.get!(Invitation, first.id).revoked_at
    assert {:error, :invalid_invitation} = Workspaces.get_invitation(first_token)
    assert [pending] = Workspaces.list_pending_invitations(scope)
    assert pending.id == second.id

    assert {:ok, _} = Workspaces.revoke_invitation(scope, second.id)
    assert {:error, :invalid_invitation} = Workspaces.get_invitation(second_token)

    {:ok, expired, expired_token} = Workspaces.create_invitation(scope, %{email: email})

    expired
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()

    assert {:error, :invalid_invitation} = Workspaces.get_invitation(expired_token)
    assert {:error, :invalid_invitation} = Workspaces.accept_invitation(scope, expired_token)
    assert Workspaces.list_pending_invitations(scope) == []

    for invalid <- [nil, "", "invalid", String.duplicate("x", 43)] do
      assert {:error, :invalid_invitation} = Workspaces.get_invitation(invalid)
    end
  end

  test "removal revokes stale scopes and cached authorized board writes", %{scope: owner_scope} do
    member_scope = join_scope(owner_scope)
    board = Boards.get_workspace_board!(member_scope)
    {:ok, item} = Boards.create_work_item(member_scope, %{title: "Member task"})
    {:ok, _} = Chat.create_message(member_scope, message_attrs("Member message"))
    assert Workspaces.subscribe(member_scope) == :ok
    assert {:ok, _} = Workspaces.remove_member(owner_scope, member_scope.membership.id)
    assert_receive {:workspace_access_changed, workspace_id}
    assert workspace_id == owner_scope.workspace.id

    refute Workspaces.authorized_scope?(member_scope)
    assert Workspaces.list_workspaces(member_scope) == []
    assert Workspaces.list_members(member_scope) == []
    assert Boards.list_work_items(member_scope) == []
    assert Chat.list_messages(member_scope) == []
    assert {:error, :unauthorized} = Boards.create_work_item(member_scope, %{title: "Revoked"})

    assert {:error, :unauthorized} =
             Boards.update_work_item(member_scope, item, %{title: "Revoked"})

    assert {:error, :unauthorized} =
             Boards.create_work_item(board, %{title: "Cached revoked board"})

    assert {:error, :unauthorized} = Chat.create_message(member_scope, message_attrs("Revoked"))
    assert {:error, :forbidden} = Workspaces.subscribe(member_scope)
    assert Boards.get_work_item(owner_scope, item.id).title == "Member task"
  end

  test "removal also revokes an outstanding invitation for that account", %{scope: scope} do
    member = user_fixture()
    {:ok, pending, token} = Workspaces.create_invitation(scope, %{email: member.email})
    membership = Repo.insert!(%Membership{workspace_id: scope.workspace.id, user_id: member.id})
    assert {:ok, _} = Workspaces.remove_member(scope, membership.id)
    assert Repo.get!(Invitation, pending.id).revoked_at

    assert {:error, :invalid_invitation} =
             Workspaces.accept_invitation(Scope.for_user(member), token)
  end

  test "legacy shared work is claimed once and keeps its tasks and conversation", %{owner: first} do
    board = Boards.get_default_board!()
    {:ok, item} = Boards.create_work_item(board, %{title: "Existing task"})

    {:ok, message} =
      Chat.create_message(
        board,
        Map.put(message_attrs("Existing discussion"), :sender_name, "Guest")
      )

    second = user_fixture()

    assert {:ok, legacy} = Workspaces.claim_legacy_workspace(first)
    assert legacy.legacy
    assert legacy.legacy_claimed
    assert {:ok, claimed_again} = Workspaces.claim_legacy_workspace(first)
    assert claimed_again.id == legacy.id
    assert {:ok, nil} = Workspaces.claim_legacy_workspace(second)
    assert {:error, :not_found} = Workspaces.fetch_scope(Scope.for_user(second), legacy.id)

    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(first), legacy.id)
    assert Boards.get_workspace_board!(scope).id == board.id
    assert Boards.get_work_item(scope, item.id).title == "Existing task"
    assert [persisted] = Chat.list_messages(scope)
    assert persisted.id == message.id
    assert persisted.sender_name == "Guest"
    assert persisted.user_id == nil
  end

  test "registration and the initial legacy claim commit atomically" do
    legacy = Workspaces.get_legacy_workspace!()
    users_before = Repo.aggregate(Devloom.Accounts.User, :count)
    invalid = valid_user_attributes(%{password: "short", password_confirmation: "short"})

    assert {:error, changeset} = Workspaces.register_user_with_legacy_workspace(invalid)
    assert Map.has_key?(errors_on(changeset), :password)
    assert Repo.aggregate(Devloom.Accounts.User, :count) == users_before
    refute Repo.get!(Workspace, legacy.id).legacy_claimed

    refute Repo.exists?(
             from membership in Membership, where: membership.workspace_id == ^legacy.id
           )

    assert {:ok, user} = Workspaces.register_user_with_legacy_workspace(valid_user_attributes())
    assert Repo.get!(Workspace, legacy.id).legacy_claimed
    assert {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), legacy.id)
    assert scope.membership.role == :owner

    assert {:ok, later} = Workspaces.register_user_with_legacy_workspace(valid_user_attributes())
    assert {:error, :not_found} = Workspaces.fetch_scope(Scope.for_user(later), legacy.id)
  end

  defp create_scope(name) do
    scope = Scope.for_user(user_fixture())
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: name})
    {:ok, scope} = Workspaces.fetch_scope(scope, workspace.id)
    scope
  end

  defp join_scope(owner_scope) do
    user = user_fixture()
    {:ok, _invitation, token} = Workspaces.create_invitation(owner_scope, %{email: user.email})
    {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    scope
  end

  defp message_attrs(body), do: %{body: body, client_ref: Ecto.UUID.generate()}
end
