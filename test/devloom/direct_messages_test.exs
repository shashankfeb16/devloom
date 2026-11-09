defmodule Devloom.DirectMessagesTest do
  use Devloom.DataCase

  import Devloom.AccountsFixtures

  alias Devloom.Accounts.Scope
  alias Devloom.DirectMessages.{Conversation, Message}
  alias Devloom.{Chat, DirectMessages, Workspaces}

  setup do
    owner = user_fixture(%{name: "Owner"})
    {:ok, workspace} = Workspaces.create_workspace(Scope.for_user(owner), %{name: "Direct team"})
    {:ok, owner_scope} = Workspaces.fetch_scope(Scope.for_user(owner), workspace.id)
    peer_scope = join_workspace(owner_scope, user_fixture(%{name: "Teammate"}))
    third_scope = join_workspace(owner_scope, user_fixture(%{name: "Other teammate"}))
    %{scope: owner_scope, peer: peer_scope, third: third_scope}
  end

  test "each workspace and canonical pair share exactly one conversation", %{
    scope: scope,
    peer: peer
  } do
    assert {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)

    assert {:ok, reverse} =
             DirectMessages.open_conversation(peer, Integer.to_string(scope.user.id))

    assert conversation.id == reverse.id
    assert conversation.participant_one_id < conversation.participant_two_id

    assert Enum.sort([scope.user.id, peer.user.id]) == [
             conversation.participant_one_id,
             conversation.participant_two_id
           ]

    assert DirectMessages.get_peer(scope, conversation).id == peer.user.id
    assert DirectMessages.get_peer(peer, conversation).id == scope.user.id

    {:ok, other_workspace} = Workspaces.create_workspace(scope, %{name: "Another shared team"})
    {:ok, other_scope} = Workspaces.fetch_scope(scope, other_workspace.id)
    other_peer = join_workspace(other_scope, peer.user)
    assert {:ok, other} = DirectMessages.open_conversation(other_scope, other_peer.user.id)
    assert other.id != conversation.id
    assert other.workspace_id == other_workspace.id
    assert Repo.aggregate(Conversation, :count) == 2
  end

  test "messages persist and derive their author from the authenticated account", %{
    scope: scope,
    peer: peer,
    third: third
  } do
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    {:ok, foreign} = DirectMessages.open_conversation(scope, third.user.id)
    forged_scope = %{scope | user: %{scope.user | name: "An invented name"}}

    assert {:ok, message} =
             DirectMessages.create_message(
               forged_scope,
               conversation,
               attrs(%{
                 body: "  Ready for review.\nPlease check the task.  ",
                 sender_name: "Impersonation",
                 user_id: third.user.id,
                 conversation_id: foreign.id
               })
             )

    assert message.user_id == scope.user.id
    assert message.sender_name == scope.user.name
    assert message.conversation_id == conversation.id
    assert message.body == "Ready for review.\nPlease check the task."
    assert %DateTime{} = message.inserted_at
    assert Repo.get!(Message, message.id) == message
    assert DirectMessages.list_messages(scope, conversation) == [message]
    assert DirectMessages.list_messages(peer, conversation) == [message]
    assert DirectMessages.list_messages(scope, foreign) == []
  end

  test "a workspace owner cannot inspect or subscribe to a private pair they are not part of", %{
    scope: owner,
    peer: peer,
    third: third
  } do
    {:ok, private} = DirectMessages.open_conversation(peer, third.user.id)
    {:ok, message} = DirectMessages.create_message(peer, private, attrs())
    assert DirectMessages.list_messages(third, private) == [message]

    assert DirectMessages.list_messages(owner, private) == []
    assert DirectMessages.get_peer(owner, private) == nil
    assert {:error, :not_found} = DirectMessages.subscribe(owner, private)
    assert {:error, :not_found} = DirectMessages.create_message(owner, private, attrs())

    forged = %{private | participant_one_id: owner.user.id, participant_two_id: peer.user.id}
    assert DirectMessages.list_messages(owner, forged) == []
    assert {:error, :not_found} = DirectMessages.create_message(owner, forged, attrs())
    assert {:error, :not_found} = DirectMessages.subscribe(owner, forged)

    outsider = user_fixture() |> Scope.for_user()
    {:ok, workspace} = Workspaces.create_workspace(outsider, %{name: "Outside team"})
    {:ok, outsider} = Workspaces.fetch_scope(outsider, workspace.id)
    assert DirectMessages.list_messages(outsider, private) == []
    assert {:error, :not_found} = DirectMessages.subscribe(outsider, private)
    assert {:error, :not_found} = DirectMessages.create_message(outsider, private, attrs())

    forged_workspace = %{peer | workspace: workspace}
    assert DirectMessages.list_messages(forged_workspace, private) == []

    assert {:error, :not_found} =
             DirectMessages.create_message(forged_workspace, private, attrs())
  end

  test "only two distinct current members may open a conversation", %{scope: scope, peer: peer} do
    outsider = user_fixture()
    assert {:error, :invalid_participant} = DirectMessages.open_conversation(scope, scope.user.id)
    assert {:error, :not_found} = DirectMessages.open_conversation(scope, outsider.id)

    for id <- [nil, "", "bad-id", "1suffix", 0, -1, %{}, 9_223_372_036_854_775_808] do
      assert {:error, :not_found} = DirectMessages.open_conversation(scope, id)
    end

    assert {:error, :not_found} = DirectMessages.open_conversation(nil, peer.user.id)

    assert {:error, :not_found} =
             DirectMessages.open_conversation(Scope.for_user(outsider), peer.user.id)

    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "removing either participant revokes cached access and reinviting preserves history", %{
    scope: scope,
    peer: peer
  } do
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    {:ok, original} = DirectMessages.create_message(scope, conversation, attrs())
    assert :ok = DirectMessages.subscribe(peer, conversation)

    assert {:ok, _workspace} = Workspaces.remove_member(scope, peer.membership.id)

    for actor <- [scope, peer] do
      assert DirectMessages.list_messages(actor, conversation) == []
      assert DirectMessages.get_peer(actor, conversation) == nil
      assert {:error, :not_found} = DirectMessages.create_message(actor, conversation, attrs())
      assert {:error, :not_found} = DirectMessages.subscribe(actor, conversation)
    end

    refute_received {:direct_message_created, _, _}

    peer = join_workspace(scope, peer.user)
    assert {:ok, restored} = DirectMessages.open_conversation(peer, scope.user.id)
    assert restored.id == conversation.id
    assert DirectMessages.list_messages(peer, restored) == [original]

    assert {:ok, _reply} =
             DirectMessages.create_message(peer, restored, attrs(%{body: "I'm back"}))
  end

  test "invalid bodies and retry references never persist or broadcast", %{
    scope: scope,
    peer: peer
  } do
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    DirectMessages.subscribe(scope, conversation)

    for body <- [nil, "", " \t\n "] do
      assert {:error, changeset} =
               DirectMessages.create_message(scope, conversation, attrs(%{body: body}))

      assert changeset.action == :insert
      assert "can't be blank" in errors_on(changeset).body
    end

    assert {:error, changeset} =
             DirectMessages.create_message(
               scope,
               conversation,
               attrs(%{body: String.duplicate("界", 4_001)})
             )

    assert "should be at most 4000 character(s)" in errors_on(changeset).body

    for ref <- [nil, "", "not-a-uuid"] do
      assert {:error, changeset} =
               DirectMessages.create_message(scope, conversation, attrs(%{client_ref: ref}))

      assert Map.has_key?(errors_on(changeset), :client_ref)
    end

    assert DirectMessages.list_messages(scope, conversation) == []
    refute_received {:direct_message_created, _, _}
  end

  test "retries are idempotent and another participant cannot reuse their reference", %{
    scope: scope,
    peer: peer,
    third: third
  } do
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    DirectMessages.subscribe(scope, conversation)
    params = attrs()
    assert {:ok, original} = DirectMessages.create_message(scope, conversation, params)
    assert_receive {:direct_message_created, conversation_id, ^original}
    assert conversation_id == conversation.id

    assert {:ok, ^original} =
             DirectMessages.create_message(
               scope,
               conversation,
               Map.put(params, :body, "A retry with changed text")
             )

    refute_received {:direct_message_created, _, _}

    assert {:error, :invalid_client_ref} =
             DirectMessages.create_message(peer, conversation, params)

    assert DirectMessages.list_messages(scope, conversation) == [original]

    {:ok, other} = DirectMessages.open_conversation(scope, third.user.id)
    assert {:ok, other_message} = DirectMessages.create_message(scope, other, params)
    assert other_message.id != original.id
  end

  test "private broadcasts stay out of team chat and every other private conversation", %{
    scope: scope,
    peer: peer,
    third: third
  } do
    {:ok, selected} = DirectMessages.open_conversation(scope, peer.user.id)
    {:ok, other} = DirectMessages.open_conversation(scope, third.user.id)
    assert :ok = Chat.subscribe(scope)
    assert :ok = Workspaces.subscribe(scope)
    assert :ok = DirectMessages.subscribe(scope, selected)

    {:ok, _message} = DirectMessages.create_message(scope, other, attrs())
    refute_received {:direct_message_created, _, _}
    refute_received {:message_created, _}
    refute_received {:workspace_access_changed, _}

    {:ok, message} = DirectMessages.create_message(peer, selected, attrs())
    assert_receive {:direct_message_created, selected_id, ^message}
    assert selected_id == selected.id
    refute_received {:message_created, _}
    refute_received {:workspace_access_changed, _}

    assert :ok = DirectMessages.unsubscribe(selected)
    {:ok, _message} = DirectMessages.create_message(peer, selected, attrs())
    refute_received {:direct_message_created, _, _}
  end

  test "history pages are chronological, bounded, and robust against invalid cursors", %{
    scope: scope,
    peer: peer
  } do
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    messages = insert_messages(scope, conversation, 205)
    ids = Enum.map(messages, & &1.id)

    assert message_ids(DirectMessages.list_messages(scope, conversation)) == Enum.take(ids, -50)

    assert message_ids(DirectMessages.list_messages(scope, conversation, limit: 3)) ==
             Enum.take(ids, -3)

    assert message_ids(
             DirectMessages.list_messages(scope, conversation,
               before_id: Enum.at(ids, 5),
               limit: 3
             )
           ) == Enum.slice(ids, 2, 3)

    assert message_ids(
             DirectMessages.list_messages(scope, conversation, after_id: hd(ids), limit: 3)
           ) == Enum.slice(ids, 1, 3)

    assert message_ids(DirectMessages.list_messages(scope, conversation, after_id: "0", limit: 3)) ==
             Enum.take(ids, 3)

    assert length(DirectMessages.list_messages(scope, conversation, limit: 10_000)) == 200
    assert DirectMessages.list_messages(scope, conversation, before_id: hd(ids)) == []
    assert DirectMessages.list_messages(scope, conversation, after_id: List.last(ids)) == []

    for cursor <- ["invalid", "1suffix", "", -1, %{}, false, 9_223_372_036_854_775_808] do
      assert DirectMessages.list_messages(scope, conversation, before_id: cursor) == []
      assert DirectMessages.list_messages(scope, conversation, after_id: cursor) == []
    end

    assert DirectMessages.list_messages(scope, conversation, before_id: 0) == []
    assert DirectMessages.list_messages(scope, conversation, before_id: 2, after_id: 1) == []

    for limit <- [nil, 0, -1, "all"] do
      assert length(DirectMessages.list_messages(scope, conversation, limit: limit)) == 50
    end

    for id <- [nil, "bad-id", -1, 9_000_000_000] do
      assert DirectMessages.list_messages(scope, id) == []
      assert DirectMessages.get_peer(scope, id) == nil
      assert {:error, :not_found} = DirectMessages.create_message(scope, id, attrs())
      assert {:error, :not_found} = DirectMessages.subscribe(scope, id)
    end
  end

  defp join_workspace(owner_scope, user) do
    {:ok, _invitation, token} = Workspaces.create_invitation(owner_scope, %{email: user.email})
    {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    scope
  end

  defp attrs(overrides \\ %{}),
    do: Map.merge(%{body: "A private team update", client_ref: Ecto.UUID.generate()}, overrides)

  defp message_ids(messages), do: Enum.map(messages, & &1.id)

  defp insert_messages(scope, conversation, count) do
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        %{
          conversation_id: conversation.id,
          user_id: scope.user.id,
          sender_name: scope.user.name,
          body: "Private message #{index}",
          client_ref: Ecto.UUID.generate(),
          inserted_at: now
        }
      end

    {_count, messages} = Repo.insert_all(Message, rows, returning: true)
    messages
  end
end
