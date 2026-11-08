defmodule DevloomWeb.InvitationLive do
  use DevloomWeb, :live_view

  alias Devloom.Workspaces

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Workspace invitation",
       token: token,
       return_to: "/invitations/#{token}"
     )
     |> load_invitation()}
  end

  @impl true
  def handle_event(
        "accept_invitation",
        _params,
        %{assigns: %{current_scope: %{user: %{id: _id}}}} = socket
      ) do
    case Workspaces.accept_invitation(socket.assigns.current_scope, socket.assigns.token) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Welcome to #{workspace.name}. You're now part of the team.")
         |> push_navigate(to: ~p"/workspaces/#{workspace.id}/board")}

      {:error, :wrong_email} ->
        {:noreply, assign(socket, invitation_state: :wrong_email)}

      {:error, _reason} ->
        {:noreply, assign(socket, invitation_state: :invalid, invitation: nil)}
    end
  end

  def handle_event("accept_invitation", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/users/log_in?#{[return_to: socket.assigns.return_to]}")}
  end

  defp load_invitation(socket) do
    case socket.assigns.current_scope do
      %{user: %{email: email}} ->
        case Workspaces.get_invitation(socket.assigns.token) do
          {:ok, invitation} ->
            state =
              if String.downcase(email) == String.downcase(invitation.email),
                do: :ready,
                else: :wrong_email

            assign(socket, invitation_state: state, invitation: invitation)

          {:error, _reason} ->
            assign(socket, invitation_state: :invalid, invitation: nil)
        end

      _ ->
        assign(socket, invitation_state: :anonymous, invitation: nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="workspaces">
      <section
        id="workspace-invitation-page"
        class="workspace-invitation-page"
        aria-labelledby="invitation-title"
      >
        <div class="workspace-accept-card">
          <span class="workspace-accept-icon"><.icon name="hero-envelope-open" class="size-7" /></span>
          <div class="page-eyebrow">GOOD WORK STARTS WITH PEOPLE</div>
          <%= case @invitation_state do %>
            <% :anonymous -> %>
              <h1 id="invitation-title">Your team is waiting.</h1>
              <p>Sign in or create an account to view and accept your workspace invitation.</p>
              <div class="workspace-accept-actions">
                <.link
                  id="invitation-sign-in"
                  href={~p"/users/log_in?#{[return_to: @return_to]}"}
                  class="button button-primary"
                >Sign in to continue<.icon name="hero-arrow-right" class="size-4" /></.link><.link
                  id="invitation-sign-up"
                  href={~p"/users/register?#{[return_to: @return_to]}"}
                  class="button button-secondary"
                >Create an account</.link>
              </div>
            <% :ready -> %>
              <h1 id="invitation-title">Join {@invitation.workspace.name}.</h1>
              <p>
                Bring your work and ideas to the team. You'll get access to this workspace's board, tasks, and conversations.
              </p>
              <div class="workspace-accept-identity">
                <.icon name="hero-user-circle" class="size-4" />Joining as
                <strong>{@current_scope.user.email}</strong>
              </div>
              <button
                id="accept-invitation"
                type="button"
                class="button button-primary"
                phx-click="accept_invitation"
                phx-disable-with="Joining…"
              >Join workspace<.icon name="hero-arrow-right" class="size-4" /></button>
              <span class="workspace-invitation-expiry">Invitation expires {Calendar.strftime(
                @invitation.expires_at,
                "%d %b %Y, %H:%M UTC"
              )}</span>
            <% :wrong_email -> %>
              <h1 id="invitation-title">Use the invited account.</h1>
              <p>
                This invitation belongs to another email address. Sign in with the account your workspace owner invited, or ask them for a new link.
              </p>
              <div id="invitation-wrong-account" class="workspace-wrong-account">
                You're signed in as <strong>{@current_scope.user.email}</strong>.
              </div>
              <.link
                id="invitation-switch-account"
                href={~p"/users/log_in?#{[return_to: @return_to]}"}
                class="button button-primary"
              >Sign in with another account</.link>
            <% :invalid -> %>
              <h1 id="invitation-title">This invitation has ended.</h1>
              <p id="invitation-invalid">
                The link may have expired, been revoked, or already been used. Ask a workspace owner for a fresh invitation.
              </p>
              <.link navigate={~p"/workspaces"} class="button button-secondary">Go to your workspaces<.icon
                name="hero-arrow-right"
                class="size-4"
              /></.link>
          <% end %>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
