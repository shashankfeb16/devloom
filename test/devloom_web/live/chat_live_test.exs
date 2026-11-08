defmodule DevloomWeb.ChatLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Devloom.{Chat, Repo}

  setup %{conn: conn} do
    setup_workspace(conn)
  end

  test "team chat is reachable from the board and starts with an accessible composer", %{
    conn: conn
  } do
    {:ok, board_view, _html} = live(conn, board_path(conn))

    assert has_element?(board_view, "#nav-chat[href='#{chat_path(conn)}']")
    assert has_element?(board_view, "#mobile-nav-chat[href='#{chat_path(conn)}']")

    {:ok, view, _html} = live(conn, chat_path(conn))

    assert has_element?(view, "#chat-page")
    assert has_element?(view, "#chat-messages[phx-update='stream']")

    assert has_element?(view, "#chat-sender-name", "Alex")

    assert has_element?(
             view,
             "#chat-message-form textarea[name='message[body]'][maxlength='4000']"
           )

    assert has_element?(view, "#send-message[type='submit']")
    refute has_element?(view, "#chat-messages [id^='chat-message-']")
    refute has_element?(view, "#load-older-messages")
  end

  test "sending a message persists it, clears the body and keeps the sender name", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, chat_path(conn))

    submit_message(view, "Alex", "The release is ready.\nPlease review the checklist.")

    [message] = Chat.list_messages(board)
    assert message.sender_name == "Alex"
    assert message.body == "The release is ready.\nPlease review the checklist."
    assert has_element?(view, "#chat-message-#{message.id}", "The release is ready.")
    assert has_element?(view, "#chat-message-#{message.id}", "Please review the checklist.")

    assert has_element?(view, "#chat-sender-name", "Alex")

    refute has_element?(view, "#chat-message-form textarea[name='message[body]']", message.body)
  end

  test "invalid messages keep the draft and never enter the conversation", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, chat_path(conn))

    submit_message(view, "Alex", "   ")
    assert Chat.list_messages(board) == []

    long_body = String.duplicate("x", 4001)
    submit_message(view, "Alex", long_body)

    assert Chat.list_messages(board) == []
    assert has_element?(view, "#chat-message-form textarea[name='message[body]']", long_body)

    assert has_element?(view, "#chat-sender-name", "Alex")
  end

  test "a second connected chat receives messages and repeated notifications do not duplicate them",
       %{
         conn: conn,
         board: board
       } do
    {:ok, first, _html} = live(conn, chat_path(conn))
    {:ok, second, _html} = live(second_conn(conn), chat_path(conn))

    submit_message(first, "Alex", "Can someone check the deployment?")

    [message] = Chat.list_messages(board)
    assert has_element?(first, "#chat-message-#{message.id}")
    assert has_element?(second, "#chat-message-#{message.id}")

    send(second.pid, {:message_created, message})
    send(second.pid, {:message_created, message})

    assert has_element?(second, "#chat-message-#{message.id}")
    refute has_element?(second, "#chat-message-#{message.id} ~ #chat-message-#{message.id}")
    assert length(Chat.list_messages(board)) == 1
  end

  test "older history loads in chronological order without replacing the newest messages", %{
    conn: conn,
    board: board
  } do
    messages = for index <- 1..55, do: create_message(board, %{body: "Message #{index}"})
    first = hd(messages)
    sixth = Enum.at(messages, 5)
    latest = List.last(messages)
    {:ok, view, _html} = live(conn, chat_path(conn))

    refute has_element?(view, "#chat-message-#{first.id}")
    assert has_element?(view, "#chat-message-#{sixth.id}")
    assert has_element?(view, "#chat-message-#{latest.id}")
    assert has_element?(view, "#load-older-messages")

    view |> element("#load-older-messages") |> render_click()

    assert has_element?(view, "#chat-message-#{first.id}")
    assert has_element?(view, "#chat-message-#{latest.id}")

    assert rendered_message_ids(view) == Enum.map(messages, & &1.id)

    refute has_element?(view, "#load-older-messages")

    incoming = create_message(board, %{body: "An update while reading older messages"})

    assert has_element?(view, "#chat-message-#{first.id}")
    refute has_element?(view, "#chat-message-#{incoming.id}")
    assert has_element?(view, "#jump-to-latest")

    view |> element("#jump-to-latest") |> render_click()

    assert has_element?(view, "#chat-message-#{incoming.id}")
    refute has_element?(view, "#chat-message-#{first.id}")
  end

  test "message ownership follows account IDs for history and live updates even when names match",
       %{
         conn: conn,
         scope: scope,
         board: board,
         user: user,
         workspace: workspace
       } do
    teammate = Devloom.AccountsFixtures.user_fixture(%{name: user.name})

    {:ok, _invitation, token} =
      Devloom.Workspaces.create_invitation(scope, %{email: teammate.email})

    teammate_scope = Devloom.Accounts.Scope.for_user(teammate)
    {:ok, _workspace} = Devloom.Workspaces.accept_invitation(teammate_scope, token)
    {:ok, teammate_scope} = Devloom.Workspaces.fetch_scope(teammate_scope, workspace.id)

    legacy = create_message(board, %{sender_name: user.name, body: "An older guest message"})
    own_older = create_message(scope, %{body: "My older message"})
    teammate_older = create_message(teammate_scope, %{body: "My teammate's older message"})

    for index <- 1..50, do: create_message(scope, %{body: "Recent message #{index}"})

    {:ok, own_view, _html} = live(conn, chat_path(conn))
    teammate_conn = log_in_user(build_conn(), teammate)
    {:ok, teammate_view, _html} = live(teammate_conn, chat_path(conn))

    for view <- [own_view, teammate_view] do
      refute has_element?(view, "#chat-message-#{legacy.id}")
      view |> element("#load-older-messages") |> render_click()
      assert has_element?(view, "#chat-message-#{legacy.id}[data-own-message='false']")
    end

    assert has_element?(own_view, "#chat-message-#{own_older.id}[data-own-message='true']")
    assert has_element?(teammate_view, "#chat-message-#{own_older.id}[data-own-message='false']")
    assert has_element?(own_view, "#chat-message-#{teammate_older.id}[data-own-message='false']")

    assert has_element?(
             teammate_view,
             "#chat-message-#{teammate_older.id}[data-own-message='true']"
           )

    for view <- [own_view, teammate_view],
        do: view |> element("#jump-to-latest") |> render_click()

    submit_message(own_view, user.name, "A new message from me")
    own_live = scope |> Chat.list_messages() |> List.last()
    assert has_element?(own_view, "#chat-message-#{own_live.id}[data-own-message='true']")
    assert has_element?(teammate_view, "#chat-message-#{own_live.id}[data-own-message='false']")

    submit_message(teammate_view, teammate.name, "A live reply from my teammate")
    teammate_live = scope |> Chat.list_messages() |> List.last()
    assert has_element?(own_view, "#chat-message-#{teammate_live.id}[data-own-message='false']")

    assert has_element?(
             teammate_view,
             "#chat-message-#{teammate_live.id}[data-own-message='true']"
           )
  end

  test "saved history appears in a new session and message markup is displayed as text", %{
    conn: conn,
    board: board
  } do
    body = "<script>alert('hello')</script> & <strong>plain text</strong>"
    message = create_message(board, %{sender_name: "<b>Alex</b>", body: body})
    {:ok, view, _html} = live(conn, chat_path(conn))

    assert has_element?(view, "#chat-message-#{message.id}", body)
    assert has_element?(view, "#chat-message-#{message.id}", "<b>Alex</b>")
    refute has_element?(view, "#chat-message-#{message.id} script")
    refute has_element?(view, "#chat-message-#{message.id} b")

    {:ok, new_session, _html} = live(second_conn(conn), chat_path(conn))
    assert has_element?(new_session, "#chat-message-#{message.id}", body)
  end

  test "messages from another workspace never appear in this chat", %{conn: conn} do
    other = setup_workspace(build_conn()).board
    {:ok, view, _html} = live(conn, chat_path(conn))

    message = create_message(other, %{body: "A separate team's conversation"})

    refute has_element?(view, "#chat-message-#{message.id}")

    {:ok, reloaded, _html} = live(second_conn(conn), chat_path(conn))
    refute has_element?(reloaded, "#chat-message-#{message.id}")
  end

  test "history and live updates keep at most 150 messages in the rendered window", %{
    conn: conn,
    board: board
  } do
    messages = for index <- 1..170, do: create_message(board, %{body: "Saved message #{index}"})
    {:ok, history, _html} = live(conn, chat_path(conn))

    for _page <- 1..3 do
      history |> element("#load-older-messages") |> render_click()
      refute has_element?(history, "#chat-messages > article:nth-of-type(151)")
    end

    assert has_element?(history, "#chat-message-#{hd(messages).id}")
    assert has_element?(history, "#chat-messages > article:nth-of-type(150)")

    {:ok, latest, _html} = live(second_conn(conn), chat_path(conn))

    incoming = for index <- 1..101, do: create_message(board, %{body: "Live update #{index}"})

    assert has_element?(latest, "#chat-message-#{List.last(incoming).id}")
    assert has_element?(latest, "#chat-messages > article:nth-of-type(150)")
    refute has_element?(latest, "#chat-messages > article:nth-of-type(151)")
    refute has_element?(latest, "#chat-message-#{Enum.at(messages, 120).id}")
    assert has_element?(latest, "#load-older-messages")
  end

  test "a newer notification arriving first fetches the committed messages in order", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, chat_path(conn))
    earlier = persist_without_broadcast(board, "Earlier committed message")
    later = persist_without_broadcast(board, "Later committed message")

    send(view.pid, {:message_created, later})
    send(view.pid, {:message_created, earlier})

    assert rendered_message_ids(view) == [earlier.id, later.id]
    refute has_element?(view, "#chat-message-#{earlier.id} ~ #chat-message-#{earlier.id}")
    refute has_element?(view, "#chat-message-#{later.id} ~ #chat-message-#{later.id}")
  end

  test "a single notification catches up a burst larger than one database page", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, chat_path(conn))
    timestamp = DateTime.utc_now()

    rows =
      for index <- 1..225 do
        %{
          board_id: board.id,
          sender_name: "Alex",
          body: "Committed update #{index}",
          client_ref: Ecto.UUID.generate(),
          inserted_at: timestamp
        }
      end

    {225, inserted} = Repo.insert_all(Devloom.Chat.Message, rows, returning: [:id, :board_id])
    newest = Enum.max_by(inserted, & &1.id)
    oldest = Enum.min_by(inserted, & &1.id)

    send(view.pid, {:message_created, newest})

    assert has_element?(view, "#chat-message-#{newest.id}")
    refute has_element?(view, "#chat-message-#{oldest.id}")
    refute has_element?(view, "#chat-messages > article:nth-of-type(151)")
    assert has_element?(view, "#load-older-messages")
  end

  test "chat navigation opens the board's list and help views", %{conn: conn} do
    {:ok, chat, _html} = live(conn, chat_path(conn))

    {:ok, list, _html} =
      chat
      |> element("#nav-work-items")
      |> render_click()
      |> follow_redirect(conn, board_path(conn) <> "?view=list")

    assert has_element?(list, "#kanban-board[data-view='list']")

    {:ok, chat_again, _html} = live(second_conn(conn), chat_path(conn))

    {:ok, board_help, _html} =
      chat_again
      |> element("#board-help")
      |> render_click()
      |> follow_redirect(conn, board_path(conn) <> "?help=1")

    assert has_element?(board_help, "#board-guide[role='dialog']")
  end

  defp submit_message(view, _sender_name, body) do
    view
    |> form("#chat-message-form", message: %{body: body})
    |> render_submit()
  end

  defp create_message(board, attrs) do
    {:ok, message} =
      Chat.create_message(
        board,
        Map.merge(
          %{sender_name: "Alex", body: "Team update", client_ref: Ecto.UUID.generate()},
          attrs
        )
      )

    message
  end

  defp persist_without_broadcast(board, body) do
    Repo.insert!(%Devloom.Chat.Message{
      board_id: board.id,
      sender_name: "Alex",
      body: body,
      client_ref: Ecto.UUID.generate()
    })
  end

  defp rendered_message_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-messages > article")
    |> LazyHTML.to_tree()
    |> Enum.map(fn {"article", attrs, _children} ->
      {"id", id} = List.keyfind(attrs, "id", 0)
      id |> String.replace_prefix("chat-message-", "") |> String.to_integer()
    end)
  end
end
