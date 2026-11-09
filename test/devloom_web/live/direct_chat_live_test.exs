defmodule DevloomWeb.DirectChatLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Devloom.{Chat, DirectMessages, WorkspacePresence, Workspaces}
  alias Devloom.Accounts.Scope
  alias Devloom.AccountsFixtures
  alias DevloomWeb.Presence

  setup %{conn: conn} do
    on_exit(fn ->
      for pid <- Presence.fetchers_pids() do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      end
    end)

    setup_workspace(conn)
  end

  test "the chat directory offers only other members of this workspace, including offline members",
       %{
         conn: conn,
         scope: scope,
         user: user,
         workspace: workspace
       } do
    peer = add_member(scope, "Sam")
    outsider = AccountsFixtures.user_fixture(%{name: "Unrelated person"})
    {:ok, view, _html} = live(conn, chat_path(conn))

    assert has_element?(view, "#chat-directory")

    assert has_element?(
             view,
             "#chat-member-#{peer.user.id}[href='#{direct_path(workspace, peer.user)}'][data-online='false']",
             peer.user.name
           )

    refute has_element?(view, "#chat-member-#{user.id}")
    refute has_element?(view, "#chat-member-#{outsider.id}")

    view |> element("#chat-member-#{peer.user.id}") |> render_click()
    assert_patch(view, direct_path(workspace, peer.user))
    assert has_element?(view, "#chat-peer-name", peer.user.name)
    assert has_element?(view, "#chat-peer-status[data-online='false']")
    assert has_element?(view, "#chat-team-link[href='#{chat_path(conn)}']")
  end

  test "only the two participants receive private messages, including when the third member is an owner",
       %{
         conn: owner_conn,
         scope: owner_scope,
         workspace: workspace
       } do
    sam = add_member(owner_scope, "Sam")
    taylor = add_member(owner_scope, "Taylor")
    {:ok, sam_view, _html} = live(sam.conn, direct_path(workspace, taylor.user))
    {:ok, taylor_view, _html} = live(taylor.conn, direct_path(workspace, sam.user))
    {:ok, team_view, _html} = live(owner_conn, chat_path(owner_conn))
    {:ok, owner_direct, _html} = live(owner_conn, direct_path(workspace, sam.user))

    send_message(sam_view, "A private note between Sam and Taylor")
    {:ok, conversation} = DirectMessages.open_conversation(sam.scope, taylor.user.id)
    [message] = DirectMessages.list_messages(sam.scope, conversation)
    dom_id = direct_message_id(conversation, message)

    assert message.user_id == sam.user.id
    assert has_element?(sam_view, "##{dom_id}[data-own-message='true']", message.body)
    assert has_element?(taylor_view, "##{dom_id}[data-own-message='false']", message.body)
    refute has_element?(team_view, "#chat-messages", message.body)
    refute has_element?(owner_direct, "#chat-messages", message.body)
    assert Chat.list_messages(owner_scope) == []

    send(owner_direct.pid, {:direct_message_created, conversation.id, message})
    refute has_element?(owner_direct, "#chat-messages", message.body)

    send_message(taylor_view, "The private reply")
    [_, reply] = DirectMessages.list_messages(sam.scope, conversation)
    assert has_element?(sam_view, "##{direct_message_id(conversation, reply)}", reply.body)

    assert has_element?(
             taylor_view,
             "##{direct_message_id(conversation, reply)}[data-own-message='true']"
           )

    refute has_element?(team_view, "#chat-messages", reply.body)
    refute has_element?(owner_direct, "#chat-messages", reply.body)
  end

  test "a reopened private conversation shares its history in either direction and pages chronologically",
       %{
         conn: conn,
         scope: scope,
         user: user,
         workspace: workspace
       } do
    peer = add_member(scope, "Sam")
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    {:ok, reverse} = DirectMessages.open_conversation(peer.scope, user.id)
    assert reverse.id == conversation.id

    messages =
      for index <- 1..55,
          do: create_direct_message(scope, conversation, "Private update #{index}")

    {:ok, view, _html} = live(conn, direct_path(workspace, peer.user))

    assert has_element?(view, "#chat-messages[data-conversation-id='#{conversation.id}']")
    refute has_element?(view, "##{direct_message_id(conversation, hd(messages))}")
    assert has_element?(view, "##{direct_message_id(conversation, List.last(messages))}")
    view |> element("#load-older-messages") |> render_click()
    assert rendered_message_ids(view) == Enum.map(messages, & &1.id)
    refute has_element?(view, "#load-older-messages")

    {:ok, reloaded, _html} = live(peer.conn, direct_path(workspace, user))

    assert has_element?(
             reloaded,
             "##{direct_message_id(conversation, List.last(messages))}[data-own-message='false']"
           )
  end

  test "switching team and private conversations resets the visible messages and server form draft",
       %{
         conn: conn,
         scope: scope,
         workspace: workspace
       } do
    peer = add_member(scope, "Sam")
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)
    direct = create_direct_message(scope, conversation, "Private conversation history")

    {:ok, team} =
      Chat.create_message(scope, %{
        body: "The team conversation history",
        client_ref: Ecto.UUID.generate()
      })

    {:ok, view, _html} = live(conn, chat_path(conn))
    assert has_element?(view, "#chat-messages", team.body)

    view |> element("#chat-member-#{peer.user.id}") |> render_click()
    assert_patch(view, direct_path(workspace, peer.user))
    assert has_element?(view, "#chat-messages", direct.body)
    refute has_element?(view, "#chat-messages", team.body)

    view
    |> form("#chat-message-form", message: %{body: "An unsent private draft"})
    |> render_change()

    private_storage_key = storage_key(view)
    view |> element("#chat-team-link") |> render_click()
    assert_patch(view, chat_path(conn))

    assert has_element?(view, "#chat-messages[data-conversation-id='team']", team.body)
    refute has_element?(view, "#chat-messages", direct.body)
    refute has_element?(view, "#chat-message-body", "An unsent private draft")
    refute storage_key(view) == private_storage_key
  end

  test "self, foreign workspace, unknown, and malformed direct recipients cannot be opened", %{
    conn: conn,
    user: user,
    workspace: workspace
  } do
    outsider = AccountsFixtures.user_fixture()

    for id <- [user.id, outsider.id, 9_000_000_000, "not-a-user"] do
      assert {:error, {redirect_kind, %{to: destination}}} =
               live(conn, "/workspaces/#{workspace.id}/chat/direct/#{id}")

      assert redirect_kind in [:redirect, :live_redirect]
      assert destination == chat_path(conn)
    end

    response = get(build_conn(), direct_path(workspace, outsider))
    assert redirected_to(response) == "/users/log_in"
  end

  test "late composer events cannot send or replace a draft after changing recipients or channels",
       %{conn: conn, scope: scope, workspace: workspace} do
    sam = add_member(scope, "Sam")
    taylor = add_member(scope, "Taylor")
    {:ok, sam_conversation} = DirectMessages.open_conversation(scope, sam.user.id)
    {:ok, taylor_conversation} = DirectMessages.open_conversation(scope, taylor.user.id)
    {:ok, view, _html} = live(conn, direct_path(workspace, sam.user))

    destinations = [
      {"#chat-member-#{taylor.user.id}", direct_path(workspace, taylor.user)},
      {"#chat-team-link", chat_path(conn)},
      {"#chat-member-#{sam.user.id}", direct_path(workspace, sam.user)}
    ]

    for {{selector, destination}, index} <- Enum.with_index(destinations) do
      stale_context = storage_key(view)
      view |> element(selector) |> render_click()
      assert_patch(view, destination)
      current_context = storage_key(view)
      refute current_context == stale_context
      draft = "Keep the current conversation's draft #{index}"

      view |> form("#chat-message-form", message: %{body: draft}) |> render_change()

      delayed_params = %{
        "message" => %{
          "context" => stale_context,
          "body" => "This delayed message belongs to the previous conversation",
          "client_ref" => Ecto.UUID.generate()
        }
      }

      render_submit(view, "send_message", delayed_params)
      render_change(view, "validate_message", delayed_params)

      assert has_element?(view, "#chat-message-body", draft)
      assert storage_key(view) == current_context
      assert DirectMessages.list_messages(scope, sam_conversation) == []
      assert Chat.list_messages(scope) == []

      assert Enum.map(DirectMessages.list_messages(scope, taylor_conversation), & &1.body) ==
               if(index == 0, do: [], else: ["A legitimate message to Taylor"])

      if index == 0 do
        send_message(view, "A legitimate message to Taylor")

        assert [%{body: "A legitimate message to Taylor"}] =
                 DirectMessages.list_messages(scope, taylor_conversation)
      end
    end
  end

  test "removing a participant closes their open private chat and returns the remaining participant to team chat",
       %{
         conn: conn,
         scope: scope,
         workspace: workspace
       } do
    peer = add_member(scope, "Sam")
    {:ok, conversation} = DirectMessages.open_conversation(scope, peer.user.id)

    message =
      create_direct_message(scope, conversation, "History from before the membership ended")

    {:ok, owner_view, _html} = live(conn, direct_path(workspace, peer.user))
    {:ok, peer_view, _html} = live(peer.conn, direct_path(workspace, scope.user))
    membership = Enum.find(Workspaces.list_members(scope), &(&1.user_id == peer.user.id))

    assert {:ok, _} = Workspaces.remove_member(scope, membership.id)

    assert_redirect(peer_view, "/workspaces")
    assert_patch(owner_view, chat_path(conn))
    refute has_element?(owner_view, "#chat-peer-name")
    refute has_element?(owner_view, "#chat-messages", message.body)
    refute has_element?(owner_view, "#chat-member-#{peer.user.id}")
    assert DirectMessages.list_messages(scope, conversation) == []

    assert {:error, _} =
             DirectMessages.create_message(scope, conversation, %{
               body: "No longer allowed",
               client_ref: Ecto.UUID.generate()
             })

    send(owner_view.pid, {:direct_message_created, conversation.id, message})
    refute has_element?(owner_view, "#chat-messages", message.body)
  end

  test "presence updates both the directory and selected peer, remaining online until the last tab closes",
       %{
         conn: conn,
         scope: scope,
         workspace: workspace
       } do
    peer = add_member(scope, "Sam")
    :ok = WorkspacePresence.subscribe(scope)
    {:ok, observer, _html} = live(conn, direct_path(workspace, peer.user))
    assert has_element?(observer, "#chat-peer-status[data-online='false']")
    peer_key = to_string(peer.user.id)

    {:ok, first_tab, _html} = live(peer.conn, "/workspaces/#{workspace.id}/board")

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{joins: %{^peer_key => _}}
                   },
                   1_000

    finish_presence_fetchers()
    assert has_element?(observer, "#chat-member-#{peer.user.id}[data-online='true']")
    assert has_element?(observer, "#chat-peer-status[data-online='true']")

    {:ok, second_tab, _html} =
      live(log_in_user(build_conn(), peer.user), "/workspaces/#{workspace.id}/board")

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{joins: %{^peer_key => _}}
                   },
                   1_000

    finish_presence_fetchers()
    stop_view(first_tab)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{leaves: %{^peer_key => _}}
                   },
                   1_000

    finish_presence_fetchers()
    assert has_element?(observer, "#chat-peer-status[data-online='true']")

    stop_view(second_tab)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{leaves: %{^peer_key => _}}
                   },
                   1_000

    finish_presence_fetchers()
    assert has_element?(observer, "#chat-member-#{peer.user.id}[data-online='false']")
    assert has_element?(observer, "#chat-peer-status[data-online='false']")
  end

  defp add_member(owner_scope, name) do
    user = AccountsFixtures.user_fixture(%{name: name})
    {:ok, _invitation, token} = Workspaces.create_invitation(owner_scope, %{email: user.email})
    {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    %{user: user, scope: scope, conn: log_in_user(build_conn(), user)}
  end

  defp direct_path(workspace, user), do: "/workspaces/#{workspace.id}/chat/direct/#{user.id}"

  defp direct_message_id(conversation, message),
    do: "direct-message-#{conversation.id}-#{message.id}"

  defp send_message(view, body) do
    view |> form("#chat-message-form", message: %{body: body}) |> render_submit()
  end

  defp create_direct_message(scope, conversation, body) do
    {:ok, message} =
      DirectMessages.create_message(scope, conversation, %{
        body: body,
        client_ref: Ecto.UUID.generate()
      })

    message
  end

  defp rendered_message_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-messages > article")
    |> LazyHTML.to_tree()
    |> Enum.map(fn {"article", attrs, _children} ->
      {"data-message-id", id} = List.keyfind(attrs, "data-message-id", 0)
      String.to_integer(id)
    end)
  end

  defp storage_key(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-message-form")
    |> LazyHTML.to_tree()
    |> hd()
    |> elem(1)
    |> List.keyfind("data-storage-key", 0)
    |> elem(1)
  end

  defp stop_view(view) do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end

  defp finish_presence_fetchers do
    for pid <- Presence.fetchers_pids() do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end
  end
end
