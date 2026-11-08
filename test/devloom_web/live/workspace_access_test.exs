defmodule DevloomWeb.WorkspaceAccessTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Devloom.{Accounts, Boards, Chat, Workspaces}
  alias Devloom.Accounts.Scope
  alias Devloom.AccountsFixtures

  setup %{conn: conn}, do: setup_workspace(conn)

  test "signed-out requests cannot read workspaces, boards, chat, or members", %{
    workspace: workspace
  } do
    for path <- [
          "/workspaces",
          "/workspaces/#{workspace.id}/board",
          "/workspaces/#{workspace.id}/chat",
          "/workspaces/#{workspace.id}/members"
        ] do
      response = get(build_conn(), path)
      assert redirected_to(response) == "/users/log_in"
    end
  end

  test "guessing another workspace URL does not grant access", %{conn: conn} do
    other = setup_workspace(build_conn())

    for page <- ~w(board chat members) do
      assert {:error, {:live_redirect, %{to: "/workspaces"}}} =
               live(conn, "/workspaces/#{other.workspace.id}/#{page}")
    end
  end

  test "foreign task IDs cannot be read or moved from another workspace", %{
    conn: conn,
    scope: scope
  } do
    other = setup_workspace(build_conn())
    {:ok, foreign} = Boards.create_work_item(other.scope, %{title: "Private in another team"})
    {:ok, own} = Boards.create_work_item(scope, %{title: "This team's task"})
    {:ok, view, _html} = live(conn, board_path(conn))

    assert has_element?(view, "#work-item-#{own.id}")
    refute has_element?(view, "#work-item-#{foreign.id}")
    render_click(view, "edit_item", %{"id" => foreign.id})
    refute has_element?(view, "#work-item-dialog")
    render_hook(view, "move_item", %{id: foreign.id, status: "done", before_id: nil})
    assert Boards.get_work_item(other.scope, foreign.id).status == "backlog"
  end

  test "chat records the signed-in author regardless of submitted identity", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, view, _html} = live(conn, chat_path(conn))

    render_submit(view, "send_message", %{
      "message" => %{
        "body" => "A message from my account",
        "sender_name" => "Someone else",
        "user_id" => 999_999,
        "board_id" => 999_999,
        "client_ref" => Ecto.UUID.generate()
      }
    })

    [message] = Chat.list_messages(scope)
    assert message.sender_name == user.name
    assert message.user_id == user.id
    assert has_element?(view, "#chat-message-#{message.id}", user.name)
  end

  test "removing a member closes their already connected board and chat", %{
    scope: owner_scope,
    workspace: workspace
  } do
    member = AccountsFixtures.user_fixture(%{name: "Member"})
    {:ok, _invite, token} = Workspaces.create_invitation(owner_scope, %{email: member.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(member), token)
    conn = log_in_user(build_conn(), member)
    {:ok, board, _html} = live(conn, "/workspaces/#{workspace.id}/board")
    {:ok, chat, _html} = live(conn, "/workspaces/#{workspace.id}/chat")
    membership = Enum.find(Workspaces.list_members(owner_scope), &(&1.user_id == member.id))

    assert {:ok, _} = Workspaces.remove_member(owner_scope, membership.id)

    assert_redirect(board, "/workspaces")
    assert_redirect(chat, "/workspaces")
  end

  test "revoked session tokens cannot mutate an already connected view", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, board_path(conn))
    :ok = Accounts.delete_user_session_token(get_session(conn, :user_token))
    render_click(view, "seed_sample", %{})

    assert_redirect(view, "/users/log_in")
    assert Boards.list_work_items(scope) == []
  end
end
