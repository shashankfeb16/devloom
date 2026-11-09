defmodule DevloomWeb.ChatLive do
  use DevloomWeb, :live_view

  alias Devloom.{Boards, Chat, DirectMessages, WorkspacePresence, Workspaces}

  @page_size 50
  @window_size 150

  @impl true
  def mount(_params, _session, socket) do
    board = Boards.get_workspace_board!(socket.assigns.current_scope)

    if connected?(socket) do
      Chat.subscribe(socket.assigns.current_scope)
      WorkspacePresence.subscribe(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Chat",
       board: board,
       connected?: connected?(socket),
       conversation: nil,
       peer: nil,
       selection_loaded?: false,
       directory_open?: false,
       member_query: "",
       member_search_form: to_form(%{"q" => ""}, as: :member_search),
       form: new_message_form(socket.assigns.current_scope),
       message_ids: [],
       older_messages?: false,
       history?: false,
       newer_messages?: false
     )
     |> stream_configure(:messages, dom_id: &message_dom_id/1)
     |> stream(:messages, [])
     |> refresh_directory()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope

    if params["workspace_id"] == to_string(scope.workspace.id) do
      peer_id = if socket.assigns.live_action == :direct, do: params["member_id"]

      case resolve_conversation(scope, peer_id) do
        {:ok, conversation, peer} ->
          changed? =
            !socket.assigns.selection_loaded? ||
              conversation_id(conversation) != conversation_id(socket.assigns.conversation)

          socket =
            if changed? do
              if connected?(socket) do
                if socket.assigns.conversation,
                  do: DirectMessages.unsubscribe(socket.assigns.conversation)

                if conversation, do: DirectMessages.subscribe(scope, conversation)
              end

              socket
              |> assign(
                conversation: conversation,
                peer: peer,
                selection_loaded?: true,
                form: new_message_form(scope),
                page_title: if(peer, do: peer.name <> " · Chat", else: "Team chat")
              )
              |> load_latest()
              |> push_event("chat:scroll-latest", %{})
            else
              socket
            end

          {:noreply, socket |> assign(directory_open?: false) |> refresh_directory()}

        {:error, _reason} ->
          {:noreply, unavailable_conversation(socket)}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/workspaces")}
    end
  end

  @impl true
  def handle_event("toggle_directory", _params, socket) do
    {:noreply, assign(socket, directory_open?: !socket.assigns.directory_open?)}
  end

  def handle_event("close_directory", _params, socket) do
    {:noreply, assign(socket, directory_open?: false)}
  end

  def handle_event("filter_members", %{"member_search" => %{"q" => query}}, socket) do
    query = String.slice(query, 0, 80)

    {:noreply,
     socket
     |> assign(
       member_query: query,
       member_search_form: to_form(%{"q" => query}, as: :member_search)
     )
     |> refresh_directory()}
  end

  def handle_event("validate_message", %{"message" => attrs}, socket) do
    if attrs["context"] == storage_key(socket) do
      changeset =
        attrs
        |> Map.put("sender_name", socket.assigns.current_scope.user.name)
        |> Chat.change_message()
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, form: to_form(changeset, as: :message))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_message", %{"message" => attrs}, socket) do
    if attrs["context"] == storage_key(socket) do
      attrs =
        attrs
        |> Map.put("sender_name", socket.assigns.current_scope.user.name)
        |> Map.put_new("client_ref", socket.assigns.form[:client_ref].value)

      case create_message(socket, attrs) do
        {:ok, message} ->
          {:noreply,
           socket
           |> assign(form: new_message_form(socket.assigns.current_scope))
           |> load_latest()
           |> push_event("chat:sent", %{
             body: message.body,
             client_ref: message.client_ref,
             storage_key: storage_key(socket)
           })
           |> push_event("chat:scroll-latest", %{})}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, form: to_form(changeset, as: :message))}

        {:error, reason}
        when reason in [:not_found, :unauthorized, :forbidden, :invalid_participant] ->
          {:noreply, unavailable_conversation(socket)}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(form: message_form(attrs))
           |> put_flash(
             :error,
             "Your message could not be sent. Your draft is still here to retry."
           )}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "The conversation changed. Open the correct conversation before sending your draft."
       )}
    end
  end

  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns.message_ids do
      [] ->
        {:noreply, socket}

      [oldest | _] ->
        {messages, more?} =
          socket |> list_messages(before_id: oldest, limit: @page_size + 1) |> page()

        ids = Enum.take(Enum.map(messages, & &1.id) ++ socket.assigns.message_ids, @window_size)

        {:noreply,
         socket
         |> assign(message_ids: ids, older_messages?: more?, history?: true)
         |> stream(:messages, Enum.reverse(messages), at: 0, limit: @window_size)}
    end
  end

  def handle_event("jump_to_latest", _params, socket) do
    {:noreply, socket |> load_latest() |> push_event("chat:scroll-latest", %{})}
  end

  @impl true
  def handle_info({:message_created, %{board_id: board_id} = message}, socket)
      when board_id == socket.assigns.board.id and is_nil(socket.assigns.conversation) do
    {:noreply, receive_message(socket, message)}
  end

  def handle_info(
        {:direct_message_created, id, message},
        %{assigns: %{conversation: %{id: id}}} = socket
      ) do
    if DirectMessages.get_peer(socket.assigns.current_scope, socket.assigns.conversation) do
      {:noreply, receive_message(socket, message)}
    else
      {:noreply, unavailable_conversation(socket)}
    end
  end

  def handle_info({:message_created, _message}, socket), do: {:noreply, socket}
  def handle_info({:direct_message_created, _id, _message}, socket), do: {:noreply, socket}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, refresh_directory(socket)}
  end

  def handle_info({:workspace_access_changed, _workspace_id}, socket) do
    if socket.assigns.conversation &&
         !DirectMessages.get_peer(socket.assigns.current_scope, socket.assigns.conversation) do
      {:noreply, unavailable_conversation(socket)}
    else
      {:noreply, refresh_directory(socket)}
    end
  end

  defp receive_message(socket, message) do
    latest_id = List.last(socket.assigns.message_ids) || 0

    cond do
      message.id <= latest_id ->
        socket

      socket.assigns.history? ->
        assign(socket, newer_messages?: true)

      true ->
        messages = list_messages(socket, after_id: latest_id, limit: 200)

        if messages != [] && List.last(messages).id < message.id do
          load_latest(socket)
        else
          ids = socket.assigns.message_ids ++ Enum.map(messages, & &1.id)

          socket
          |> assign(
            message_ids: Enum.take(ids, -@window_size),
            older_messages?: socket.assigns.older_messages? || length(ids) > @window_size
          )
          |> stream(:messages, messages, at: -1, limit: -@window_size)
        end
    end
  end

  defp load_latest(socket) do
    {messages, more?} = socket |> list_messages(limit: @page_size + 1) |> page()

    socket
    |> assign(
      message_ids: Enum.map(messages, & &1.id),
      older_messages?: more?,
      history?: false,
      newer_messages?: false
    )
    |> stream(:messages, messages, reset: true, limit: -@window_size)
  end

  defp list_messages(%{assigns: %{conversation: nil}} = socket, opts),
    do: Chat.list_messages(socket.assigns.current_scope, opts)

  defp list_messages(socket, opts),
    do:
      DirectMessages.list_messages(
        socket.assigns.current_scope,
        socket.assigns.conversation,
        opts
      )

  defp create_message(%{assigns: %{conversation: nil}} = socket, attrs),
    do: Chat.create_message(socket.assigns.current_scope, attrs)

  defp create_message(socket, attrs),
    do:
      DirectMessages.create_message(
        socket.assigns.current_scope,
        socket.assigns.conversation,
        attrs
      )

  defp resolve_conversation(_scope, nil), do: {:ok, nil, nil}

  defp resolve_conversation(scope, peer_id) do
    with {:ok, conversation} <- DirectMessages.open_conversation(scope, peer_id),
         peer when not is_nil(peer) <- DirectMessages.get_peer(scope, conversation) do
      {:ok, conversation, peer}
    else
      _ -> {:error, :not_found}
    end
  end

  defp unavailable_conversation(socket) do
    if socket.assigns.conversation, do: DirectMessages.unsubscribe(socket.assigns.conversation)

    socket
    |> assign(
      conversation: nil,
      peer: nil,
      directory_open?: false,
      form: new_message_form(socket.assigns.current_scope)
    )
    |> load_latest()
    |> refresh_directory()
    |> put_flash(
      :error,
      "This person is no longer available for a private conversation in this workspace."
    )
    |> push_patch(to: ~p"/workspaces/#{socket.assigns.current_scope.workspace.id}/chat")
  end

  defp refresh_directory(socket) do
    online_ids = WorkspacePresence.online_user_ids(socket.assigns.current_scope)

    members =
      Workspaces.list_members(socket.assigns.current_scope)
      |> Enum.reject(&(&1.user_id == socket.assigns.current_scope.user.id))
      |> Enum.sort_by(&String.downcase(&1.user.name))

    query = socket.assigns.member_query |> String.trim() |> String.downcase()

    visible =
      Enum.filter(
        members,
        &(query == "" || String.contains?(String.downcase(&1.user.name), query))
      )

    rows =
      Enum.map(visible, fn member ->
        %{
          id: member.user_id,
          user: member.user,
          online?: MapSet.member?(online_ids, member.user_id)
        }
      end)

    socket
    |> assign(
      online_ids: online_ids,
      member_count: length(members),
      visible_member_count: length(visible),
      online_member_count: Enum.count(members, &MapSet.member?(online_ids, &1.user_id))
    )
    |> stream(:chat_members, rows, reset: true, dom_id: &"chat-member-row-#{&1.id}")
  end

  defp new_message_form(scope),
    do: message_form(%{"sender_name" => scope.user.name, "client_ref" => Ecto.UUID.generate()})

  defp page(messages), do: {Enum.take(messages, -@page_size), length(messages) > @page_size}
  defp message_form(attrs), do: attrs |> Chat.change_message() |> to_form(as: :message)
  defp conversation_id(nil), do: nil
  defp conversation_id(conversation), do: conversation.id

  defp message_dom_id(%{conversation_id: conversation_id, id: id}),
    do: "direct-message-#{conversation_id}-#{id}"

  defp message_dom_id(%{id: id}), do: "chat-message-#{id}"

  defp storage_key(socket),
    do:
      storage_key(socket.assigns.current_scope, socket.assigns.board, socket.assigns.conversation)

  defp storage_key(scope, board, nil), do: "devloom:chat:#{scope.user.id}:#{board.id}"

  defp storage_key(scope, _board, conversation),
    do: "devloom:chat:#{scope.user.id}:#{scope.workspace.id}:direct:#{conversation.id}"

  defp initials(name),
    do:
      name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="chat">
      <section id="chat-page" class="chat-page" aria-labelledby="chat-title">
        <header class="page-heading chat-page-heading">
          <div>
            <div class="page-title-row">
              <h1 id="chat-title">Chat</h1>
              <span class="shared-badge"><.icon name="hero-user-group" class="size-3" />{@current_scope.workspace.name}</span>
            </div>
          </div>
          <div class="chat-heading-actions">
            <button
              id="chat-toggle-directory"
              type="button"
              class="button button-secondary chat-people-button"
              phx-click="toggle_directory"
              aria-controls="chat-directory"
              aria-expanded={to_string(@directory_open?)}
            >
              <.icon name="hero-users" class="size-4" />People
            </button>
            <.link
              navigate={~p"/workspaces/#{@current_scope.workspace.id}/board"}
              class="button button-secondary chat-board-link"
            >
              <.icon name="hero-view-columns" class="size-4" /><span>Team board</span>
            </.link>
          </div>
        </header>

        <div class={["chat-layout", @directory_open? && "directory-open"]}>
          <button
            :if={@directory_open?}
            class="chat-directory-backdrop"
            type="button"
            phx-click="close_directory"
            aria-label="Close people list"
          ></button>
          <aside
            id="chat-directory"
            class="chat-directory"
            aria-label="Workspace conversations"
            phx-window-keydown="close_directory"
            phx-key="Escape"
          >
            <div class="chat-directory-heading">
              <strong>Conversations</strong><button
                type="button"
                class="chat-directory-close"
                phx-click="close_directory"
                aria-label="Close people list"
              ><.icon name="hero-x-mark" class="size-4" /></button>
            </div>
            <.link
              id="chat-team-link"
              patch={~p"/workspaces/#{@current_scope.workspace.id}/chat"}
              class={["chat-team-link", is_nil(@peer) && "selected"]}
              aria-current={is_nil(@peer) && "page"}
            >
              <span class="chat-directory-team-icon">#</span><span><strong>Team chat</strong><small>Everyone in this workspace</small></span>
            </.link>
            <div class="chat-directory-section">
              <span>DIRECT MESSAGES</span><small>{@online_member_count} online</small>
            </div>
            <.form
              for={@member_search_form}
              id="chat-member-search"
              class="chat-directory-search"
              phx-change="filter_members"
            >
              <.input
                field={@member_search_form[:q]}
                type="search"
                label="Find a workspace member"
                placeholder="Find a member…"
                class="chat-directory-search-input"
                maxlength="80"
                phx-debounce="250"
              />
            </.form>
            <p :if={@visible_member_count == 0} class="chat-directory-empty">
              {if @member_count == 0,
                do: "Invite teammates to start a private conversation.",
                else: "No members match your search."}
            </p>
            <div id="chat-directory-members" phx-update="stream" class="chat-directory-members">
              <div :for={{dom_id, member} <- @streams.chat_members} id={dom_id}>
                <.link
                  id={"chat-member-#{member.id}"}
                  patch={~p"/workspaces/#{@current_scope.workspace.id}/chat/direct/#{member.id}"}
                  class={["chat-member-link", @peer && @peer.id == member.id && "selected"]}
                  data-online={to_string(member.online?)}
                  aria-current={@peer && @peer.id == member.id && "page"}
                >
                  <span class="chat-directory-avatar">{initials(member.user.name)}<span
                    class="presence-dot"
                    data-online={to_string(member.online?)}
                  ></span></span>
                  <span class="chat-directory-member-details"><strong>{member.user.name}</strong><small>{if member.online?,
                    do: "Online",
                    else: "Offline"}</small></span>
                </.link>
              </div>
            </div>
            <p class="chat-directory-footnote">
              <.icon name="hero-lock-closed" class="size-3" />Private messages stay between you and the person you choose.
            </p>
          </aside>
          <div class="chat-surface">
            <header class="chat-channel-heading">
              <span class="chat-channel-symbol" aria-hidden="true">{if @peer,
                do: initials(@peer.name),
                else: "#"}</span>
              <div>
                <h2 :if={@peer} id="chat-peer-name">{@peer.name}</h2>
                <span
                  :if={@peer}
                  id="chat-peer-status"
                  class="member-presence"
                  data-online={to_string(MapSet.member?(@online_ids, @peer.id))}
                ><span class="presence-dot"></span>{if MapSet.member?(@online_ids, @peer.id),
                  do: "Online",
                  else: "Offline"}</span>
                <h2 :if={!@peer}>general</h2>
                <p :if={!@peer}>One conversation for everyone in {@current_scope.workspace.name}</p>
              </div>
              <span class="chat-channel-label"><.icon name="hero-lock-closed" class="size-3.5" />{if @peer,
                do: "Private conversation",
                else: "Workspace members only"}</span>
            </header>

            <div class="chat-scroll-frame">
              <div
                id="chat-scroll"
                class="chat-scroll"
                phx-hook="ChatScroll"
                data-history={to_string(@history?)}
                tabindex="0"
                aria-label="Conversation history"
              >
                <div class="chat-history-toolbar">
                  <button
                    :if={@older_messages?}
                    id="load-older-messages"
                    type="button"
                    class="chat-history-button"
                    phx-click="load_older_messages"
                    phx-disable-with="Loading…"
                  >
                    <.icon name="hero-arrow-up" class="size-3" />Load older messages
                  </button>
                  <span :if={!@older_messages? && @message_ids != []} class="chat-history-start">This is the beginning of your conversation</span>
                </div>
                <div :if={@message_ids == []} id="chat-empty-state" class="chat-empty-state">
                  <span class="chat-empty-icon"><.icon
                    name="hero-chat-bubble-left-right"
                    class="size-7"
                  /></span>
                  <span class="chat-empty-eyebrow">{if @peer,
                    do: "JUST THE TWO OF YOU",
                    else: "A SPACE FOR YOUR TEAM"}</span>
                  <h3>
                    {if @peer,
                      do: "Say hello to #{@peer.name}.",
                      else: "Good work starts with a conversation."}
                  </h3>
                  <p>
                    {if @peer,
                      do: "Only you and #{@peer.name} can read this conversation.",
                      else:
                        "Share an update, ask a question, or say hello. Your team's conversation will live right here."}
                  </p>
                  <span class="chat-empty-hint"><.icon name="hero-arrow-down" class="size-3" />Send the first message below</span>
                </div>
                <div
                  id="chat-messages"
                  phx-update="stream"
                  data-conversation-id={
                    if @conversation, do: to_string(@conversation.id), else: "team"
                  }
                  role="log"
                  aria-label={if @peer, do: "Private messages", else: "Team messages"}
                  aria-live="polite"
                  aria-relevant="additions"
                >
                  <article
                    :for={{dom_id, message} <- @streams.messages}
                    id={dom_id}
                    class={[
                      "chat-message",
                      message.user_id == @current_scope.user.id && "chat-message-own"
                    ]}
                    data-message-id={message.id}
                    data-own-message={to_string(message.user_id == @current_scope.user.id)}
                  >
                    <span
                      :if={message.user_id != @current_scope.user.id}
                      class="chat-message-avatar"
                      aria-hidden="true"
                    >{initials(message.sender_name)}</span>
                    <div class="chat-message-content">
                      <div class="chat-message-meta">
                        <strong>{message.sender_name}</strong>
                      </div>
                      <p class="chat-message-body">{message.body}</p>
                      <time
                        id={"#{dom_id}-time"}
                        class="chat-message-time"
                        datetime={DateTime.to_iso8601(message.inserted_at)}
                        phx-hook="ChatTimestamp"
                        phx-update="ignore"
                        title={Calendar.strftime(message.inserted_at, "%d %b %Y, %H:%M UTC")}
                      >
                        {Calendar.strftime(message.inserted_at, "%d %b, %H:%M UTC")}
                      </time>
                    </div>
                  </article>
                </div>
              </div>
              <button
                id="chat-scroll-jump"
                type="button"
                class="chat-scroll-jump"
                phx-update="ignore"
                hidden
              >Jump to latest ↓</button>
            </div>

            <div :if={@history?} class="chat-history-notice" role="status">
              <span>{if @newer_messages?,
                do: "New messages are waiting.",
                else: "You're reading earlier messages."}</span>
              <button id="jump-to-latest" type="button" phx-click="jump_to_latest">Back to latest<.icon
                name="hero-arrow-down"
                class="size-3"
              /></button>
            </div>

            <.form
              for={@form}
              id="chat-message-form"
              class="chat-composer"
              phx-change="validate_message"
              phx-submit="send_message"
              phx-hook="ChatComposer"
              data-storage-key={storage_key(@current_scope, @board, @conversation)}
              data-client-ref={@form[:client_ref].value}
            >
              <.input field={@form[:client_ref]} type="hidden" />
              <.input
                type="hidden"
                name="message[context]"
                id="message-context"
                value={storage_key(@current_scope, @board, @conversation)}
              />
              <div class="chat-composer-message">
                <.input
                  field={@form[:body]}
                  id="chat-message-body"
                  type="textarea"
                  label={if @peer, do: "Message #{@peer.name}", else: "Message #general"}
                  class="chat-message-input"
                  placeholder="What's on your mind?"
                  maxlength="4000"
                  rows="2"
                  required
                  phx-debounce="300"
                  aria-describedby="chat-composer-hint"
                />
                <button
                  id="send-message"
                  type="submit"
                  class="button button-primary"
                  phx-disable-with="Sending…"
                  disabled={!@connected?}
                  aria-label="Send message"
                >
                  <span>Send message</span><.icon name="hero-paper-airplane" class="size-4" />
                </button>
              </div>
              <div class="chat-composer-footer">
                <span class="chat-signed-identity">
                  Sending as <strong id="chat-sender-name">{@current_scope.user.name}</strong>
                </span>
                <span id="chat-composer-hint">
                  <kbd>↵</kbd> new line <span>·</span>
                  <kbd>⌘ / Ctrl</kbd> + <kbd>↵</kbd> send
                </span>
              </div>
              <p id="chat-offline-notice" class="chat-offline-notice" role="status" hidden>
                Reconnecting… Your draft is kept in this tab.
              </p>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
