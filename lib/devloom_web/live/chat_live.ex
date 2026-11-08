defmodule DevloomWeb.ChatLive do
  use DevloomWeb, :live_view

  alias Devloom.{Boards, Chat}

  @page_size 50
  @window_size 150

  @impl true
  def mount(_params, _session, socket) do
    board = Boards.get_workspace_board!(socket.assigns.current_scope)
    if connected?(socket), do: Chat.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: "Team chat",
       board: board,
       connected?: connected?(socket),
       form:
         message_form(%{
           "sender_name" => socket.assigns.current_scope.user.name,
           "client_ref" => Ecto.UUID.generate()
         }),
       history?: false,
       newer_messages?: false
     )
     |> stream_configure(:messages, dom_id: &"chat-message-#{&1.id}")
     |> load_latest()}
  end

  @impl true
  def handle_event("validate_message", %{"message" => attrs}, socket) do
    changeset =
      attrs
      |> Map.put("sender_name", socket.assigns.current_scope.user.name)
      |> Chat.change_message()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :message))}
  end

  def handle_event("send_message", %{"message" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("sender_name", socket.assigns.current_scope.user.name)
      |> Map.put_new("client_ref", socket.assigns.form[:client_ref].value)

    case Chat.create_message(socket.assigns.current_scope, attrs) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(
           form:
             message_form(%{
               "sender_name" => message.sender_name,
               "client_ref" => Ecto.UUID.generate()
             })
         )
         |> load_latest()
         |> push_event("chat:sent", %{body: message.body, client_ref: message.client_ref})
         |> push_event("chat:scroll-latest", %{})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :message))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(form: message_form(attrs))
         |> put_flash(
           :error,
           "Your message could not be sent. Your draft is still here to retry."
         )}
    end
  end

  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns.message_ids do
      [] ->
        {:noreply, socket}

      [oldest | _] ->
        {messages, more?} =
          socket.assigns.current_scope
          |> Chat.list_messages(before_id: oldest, limit: @page_size + 1)
          |> page()

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
      when board_id == socket.assigns.board.id do
    latest_id = List.last(socket.assigns.message_ids) || 0

    cond do
      message.id <= latest_id ->
        {:noreply, socket}

      socket.assigns.history? ->
        {:noreply, assign(socket, newer_messages?: true)}

      true ->
        # Fetch the committed range, rather than trusting notification arrival
        # order. The context serializes inserts before assigning their IDs.
        messages =
          Chat.list_messages(socket.assigns.current_scope, after_id: latest_id, limit: 200)

        if messages != [] && List.last(messages).id < message.id do
          # A notification can overtake more than one catch-up page. Reset to a
          # bounded recent window instead of leaving the newest message missing.
          {:noreply, load_latest(socket)}
        else
          all_ids = socket.assigns.message_ids ++ Enum.map(messages, & &1.id)
          trimmed? = length(all_ids) > @window_size

          {:noreply,
           socket
           |> assign(
             message_ids: Enum.take(all_ids, -@window_size),
             older_messages?: socket.assigns.older_messages? || trimmed?
           )
           |> stream(:messages, messages, at: -1, limit: -@window_size)}
        end
    end
  end

  def handle_info({:message_created, _message}, socket), do: {:noreply, socket}

  def handle_info({:workspace_access_changed, _workspace_id}, socket), do: {:noreply, socket}

  defp load_latest(socket) do
    {messages, more?} =
      Chat.list_messages(socket.assigns.current_scope, limit: @page_size + 1) |> page()

    socket
    |> assign(
      message_ids: Enum.map(messages, & &1.id),
      older_messages?: more?,
      history?: false,
      newer_messages?: false
    )
    |> stream(:messages, messages, reset: true, limit: -@window_size)
  end

  defp page(messages), do: {Enum.take(messages, -@page_size), length(messages) > @page_size}
  defp message_form(attrs), do: attrs |> Chat.change_message() |> to_form(as: :message)

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="chat">
      <section id="chat-page" class="chat-page" aria-labelledby="chat-title">
        <header class="page-heading chat-page-heading">
          <div>
            <div class="page-eyebrow">
              <span class="eyebrow-line"></span>THE CONVERSATION CONTINUES
            </div>
            <div class="page-title-row">
              <h1 id="chat-title">Team chat</h1>
              <span class="shared-badge"><.icon name="hero-user-group" class="size-3" />Shared</span>
            </div>
            <p class="page-intro">
              A little context. A quick question. A place to keep the team in sync.
            </p>
          </div>
          <.link
            navigate={~p"/workspaces/#{@current_scope.workspace.id}/board"}
            class="button button-secondary chat-board-link"
          >
            <.icon name="hero-view-columns" class="size-4" /><span>Team board</span>
          </.link>
        </header>

        <div class="chat-surface">
          <header class="chat-channel-heading">
            <span class="chat-channel-symbol" aria-hidden="true">#</span>
            <div>
              <h2>general</h2><p>One conversation for everyone in {@current_scope.workspace.name}</p>
            </div>
            <span class="chat-channel-label"><.icon name="hero-globe-alt" class="size-3.5" />Workspace chat</span>
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
                <span class="chat-empty-eyebrow">A SPACE FOR YOUR TEAM</span>
                <h3>Good work starts with a conversation.</h3>
                <p>
                  Share an update, ask a question, or say hello.<br />Your team's conversation will live right here.
                </p>
                <span class="chat-empty-hint"><.icon name="hero-arrow-down" class="size-3" />Send the first message below</span>
              </div>
              <div
                id="chat-messages"
                phx-update="stream"
                role="log"
                aria-label="Team messages"
                aria-live="polite"
                aria-relevant="additions"
              >
                <article
                  :for={{dom_id, message} <- @streams.messages}
                  id={dom_id}
                  class="chat-message"
                  data-message-id={message.id}
                >
                  <span class="chat-message-avatar" aria-hidden="true">{initials(message.sender_name)}</span>
                  <div class="chat-message-content">
                    <div class="chat-message-meta">
                      <strong>{message.sender_name}</strong>
                      <time
                        id={"chat-time-#{message.id}"}
                        datetime={DateTime.to_iso8601(message.inserted_at)}
                        phx-hook="ChatTimestamp"
                        phx-update="ignore"
                        title={Calendar.strftime(message.inserted_at, "%d %b %Y, %H:%M UTC")}
                      >
                        {Calendar.strftime(message.inserted_at, "%d %b, %H:%M UTC")}
                      </time>
                    </div>
                    <p class="chat-message-body">{message.body}</p>
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
            data-storage-key={"devloom:chat:#{@current_scope.user.id}:#{@board.id}"}
          >
            <.input field={@form[:client_ref]} type="hidden" />
            <div class="chat-composer-identity">
              <.icon name="hero-user-circle" class="size-4" />
              <span class="chat-signed-identity">Sending as
              <strong id="chat-sender-name">{@current_scope.user.name}</strong></span>
              <span class="chat-guest-note">Workspace members only</span>
            </div>
            <div class="chat-composer-message">
              <.input
                field={@form[:body]}
                id="chat-message-body"
                type="textarea"
                label="Message #general"
                class="chat-message-input"
                placeholder="What's on your mind?"
                maxlength="4000"
                rows="3"
                required
                phx-debounce="300"
                aria-describedby="chat-composer-hint"
              />
              <div class="chat-composer-actions">
                <span id="chat-composer-hint"><kbd>↵</kbd>
                new line <span>·</span> <kbd>⌘ / Ctrl</kbd>
                + <kbd>↵</kbd>
                send</span>
                <button
                  id="send-message"
                  type="submit"
                  class="button button-primary"
                  phx-disable-with="Sending…"
                  disabled={!@connected?}
                >
                  <span>Send message</span><.icon name="hero-paper-airplane" class="size-4" />
                </button>
              </div>
            </div>
            <p class="chat-composer-footnote">
              <.icon name="hero-lock-closed" class="size-3" />Saved in your workspace. Visible to everyone with access.
            </p>
            <p id="chat-offline-notice" class="chat-offline-notice" role="status" hidden>
              Reconnecting… Your draft is kept in this tab.
            </p>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
