defmodule DevloomWeb.WorkspaceMembersLive do
  use DevloomWeb, :live_view

  alias Devloom.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Workspace members",
       form: to_form(Workspaces.change_invitation(), as: :invitation),
       invitation_url: nil,
       invitation_email: nil,
       removing_member: nil
     )
     |> refresh_members()}
  end

  @impl true
  def handle_event("validate_invitation", %{"invitation" => attrs}, socket) do
    form =
      attrs
      |> Workspaces.change_invitation()
      |> Map.put(:action, :validate)
      |> to_form(as: :invitation)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("create_invitation", %{"invitation" => attrs}, socket) do
    case Workspaces.create_invitation(socket.assigns.current_scope, attrs) do
      {:ok, invitation, token} ->
        {:noreply,
         socket
         |> assign(
           invitation_url: url(~p"/invitations/#{token}"),
           invitation_email: invitation.email,
           form: to_form(Workspaces.change_invitation(), as: :invitation)
         )
         |> refresh_members()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :invitation))}

      {:error, :already_member} ->
        {:noreply,
         put_flash(socket, :error, "This person is already a member of your workspace.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This invitation could not be created. Only workspace owners can invite members."
         )}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    case Workspaces.revoke_invitation(socket.assigns.current_scope, id) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign(invitation_url: nil, invitation_email: nil)
         |> put_flash(:info, "Invitation revoked. Its link can no longer be used.")
         |> refresh_members()}

      {:error, _reason} ->
        {:noreply,
         socket |> put_flash(:error, "This invitation could not be revoked.") |> refresh_members()}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    member =
      socket.assigns.current_scope
      |> Workspaces.list_members()
      |> Enum.find(&(to_string(&1.id) == id))

    if socket.assigns.owner? && member && member.role != :owner do
      {:noreply, assign(socket, removing_member: member)}
    else
      {:noreply, put_flash(socket, :error, "This member cannot be removed.")}
    end
  end

  def handle_event("cancel_remove_member", _params, socket) do
    {:noreply, assign(socket, removing_member: nil)}
  end

  def handle_event("confirm_remove_member", _params, %{assigns: %{removing_member: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_remove_member", _params, socket) do
    case Workspaces.remove_member(socket.assigns.current_scope, socket.assigns.removing_member.id) do
      {:ok, _member} ->
        {:noreply,
         socket
         |> assign(removing_member: nil)
         |> put_flash(:info, "Member removed. Their access to this workspace has ended.")
         |> refresh_members()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(removing_member: nil)
         |> put_flash(:error, "This member could not be removed.")
         |> refresh_members()}
    end
  end

  @impl true
  def handle_info({:workspace_access_changed, _id}, socket) do
    {:noreply, refresh_members(socket)}
  end

  defp refresh_members(socket) do
    scope = socket.assigns.current_scope
    members = Workspaces.list_members(scope)
    owner? = scope.membership.role == :owner
    invitations = if owner?, do: Workspaces.list_pending_invitations(scope), else: []

    socket
    |> assign(
      workspace: scope.workspace,
      owner?: owner?,
      member_count: length(members),
      invitation_count: length(invitations)
    )
    |> stream(:members, members, reset: true, dom_id: &"member-#{&1.id}")
    |> stream(:invitations, invitations, reset: true, dom_id: &"invitation-#{&1.id}")
  end

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_view="members">
      <section
        id="workspace-members-page"
        class="workspace-members-page"
        aria-labelledby="workspace-members-title"
      >
        <header class="page-heading workspace-page-heading">
          <div>
            <div class="page-eyebrow"><span class="eyebrow-line"></span>BUILD WITH GOOD COMPANY</div>
            <h1 id="workspace-members-title">Your team</h1>
            <p class="page-intro">The people and invitations in {@workspace.name}.</p>
          </div>
          <.link navigate={~p"/workspaces/#{@workspace.id}/board"} class="button button-secondary"><.icon
            name="hero-arrow-left"
            class="size-4"
          />Back to board</.link>
        </header>

        <div class="workspace-member-layout">
          <div class="workspace-member-directory">
            <section class="workspace-members-panel" aria-labelledby="members-section-title">
              <header class="workspace-panel-heading">
                <div>
                  <h2 id="members-section-title">Workspace members <span>{@member_count}</span></h2><p>
                    Everyone here can work on this board and join the conversation.
                  </p>
                </div><.icon name="hero-user-group" class="size-5" />
              </header>
              <div id="workspace-members" phx-update="stream">
                <article
                  :for={{dom_id, member} <- @streams.members}
                  id={dom_id}
                  class="workspace-member-row"
                >
                  <span class="workspace-member-avatar">{initials(member.user.name)}</span>
                  <div class="workspace-member-details">
                    <strong>{member.user.name}<small :if={member.user_id == @current_scope.user.id}>You</small></strong><span>{member.user.email}</span>
                  </div>
                  <span class={["workspace-role", member.role == :owner && "is-owner"]}>{if member.role ==
                                                                                              :owner,
                                                                                            do:
                                                                                              "Owner",
                                                                                            else:
                                                                                              "Member"}</span>
                  <button
                    :if={@owner? && member.role != :owner}
                    id={"remove-member-#{member.id}"}
                    type="button"
                    class="workspace-row-action"
                    phx-click="remove_member"
                    phx-value-id={member.id}
                    aria-label={"Remove #{member.user.name}"}
                  ><.icon name="hero-user-minus" class="size-4" /></button>
                </article>
              </div>
            </section>

            <div
              :if={@removing_member}
              id="remove-member-confirmation"
              class="workspace-remove-confirmation"
              role="alert"
            >
              <.icon name="hero-exclamation-triangle" class="size-5" /><div>
                <strong>Remove {@removing_member.user.name}?</strong><p>
                  They will lose access to this workspace's board and conversations. Their existing work and messages will stay.
                </p><div>
                  <button
                    id="confirm-remove-member"
                    class="button button-danger"
                    type="button"
                    phx-click="confirm_remove_member"
                  >Remove member</button><button
                    class="button button-secondary"
                    type="button"
                    phx-click="cancel_remove_member"
                  >Keep member</button>
                </div>
              </div>
            </div>

            <section
              :if={@owner?}
              class="workspace-members-panel workspace-pending-panel"
              aria-labelledby="invitations-section-title"
            >
              <header class="workspace-panel-heading">
                <div>
                  <h2 id="invitations-section-title">
                    Pending invitations <span>{@invitation_count}</span>
                  </h2><p>Invitation links expire after seven days and can be used once.</p>
                </div><.icon name="hero-envelope" class="size-5" />
              </header>
              <div
                :if={@invitation_count == 0}
                id="pending-invitations-empty"
                class="workspace-invitations-empty"
              >
                No pending invitations. Your next teammate is a link away.
              </div>
              <div id="workspace-invitations" phx-update="stream">
                <article
                  :for={{dom_id, invitation} <- @streams.invitations}
                  id={dom_id}
                  class="workspace-invitation-row"
                >
                  <span class="workspace-invitation-icon"><.icon name="hero-envelope" class="size-4" /></span><div>
                    <strong>{invitation.email}</strong><span>Expires {Calendar.strftime(
                      invitation.expires_at,
                      "%d %b %Y, %H:%M UTC"
                    )}</span>
                  </div><button
                    id={"revoke-invitation-#{invitation.id}"}
                    type="button"
                    class="workspace-revoke-button"
                    phx-click="revoke_invitation"
                    phx-value-id={invitation.id}
                  >Revoke</button>
                </article>
              </div>
            </section>
          </div>

          <aside
            :if={@owner?}
            class="workspace-create-panel workspace-invite-panel"
            aria-labelledby="invite-member-title"
          >
            <span class="workspace-create-icon"><.icon name="hero-user-plus" class="size-5" /></span>
            <h2 id="invite-member-title">Bring your people along.</h2>
            <p>
              Create a private invitation link for a teammate. Share it with them so they can join this workspace.
            </p>
            <.form
              for={@form}
              id="invite-member-form"
              class="workspace-form"
              phx-submit="create_invitation"
              phx-change="validate_invitation"
            >
              <.input
                field={@form[:email]}
                id="invitation-email"
                type="email"
                label="Teammate's email"
                class="workspace-text-input"
                placeholder="alex@yourteam.com"
                maxlength="160"
                required
                phx-debounce="300"
              />
              <button
                id="create-invitation"
                type="submit"
                class="button button-primary"
                phx-disable-with="Creating…"
              ><.icon name="hero-link" class="size-4" />Create invitation link</button>
            </.form>
            <div
              :if={@invitation_url}
              id="invitation-link-panel"
              class="workspace-created-invitation"
              role="status"
            >
              <span class="workspace-link-ready"><.icon name="hero-check-circle" class="size-4" />Invitation ready</span>
              <p>
                Share this link with <strong>{@invitation_email}</strong>. They must sign in with that email address.
              </p>
              <.input
                id="invitation-link"
                name="invitation_link"
                value={@invitation_url}
                label="Private invitation link"
                class="workspace-text-input"
                readonly
              />
              <button
                id="copy-invitation-link"
                type="button"
                class="button button-secondary"
                phx-hook=".CopyInvitation"
                phx-update="ignore"
              ><.icon name="hero-document-duplicate" class="size-3.5" /><span data-copy-label>Copy link</span></button>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyInvitation">
                export default {
                  mounted() {
                    this.copy = async () => {
                      const input = document.getElementById("invitation-link")
                      try {
                        await navigator.clipboard.writeText(input.value)
                        this.el.querySelector("[data-copy-label]").textContent = "Copied"
                        clearTimeout(this.resetTimer)
                        this.resetTimer = setTimeout(() => {
                          this.el.querySelector("[data-copy-label]").textContent = "Copy link"
                        }, 2000)
                      } catch (_) {
                        input.focus()
                        input.select()
                      }
                    }
                    this.el.addEventListener("click", this.copy)
                  },
                  destroyed() {
                    clearTimeout(this.resetTimer)
                    this.el.removeEventListener("click", this.copy)
                  },
                }
              </script>
            </div>
            <div class="workspace-create-footnote">
              <.icon name="hero-information-circle" class="size-3.5" /><span>No email is sent automatically. Send the link to your teammate yourself.</span>
            </div>
          </aside>
          <aside :if={!@owner?} class="workspace-create-panel workspace-member-note">
            <span class="workspace-create-icon"><.icon name="hero-user-group" class="size-5" /></span><h2>
              Good work takes a team.
            </h2><p>
              Workspace owners manage invitations and membership. Ask an owner when someone new needs access.
            </p><.link
              navigate={~p"/workspaces/#{@workspace.id}/chat"}
              class="button button-secondary"
            ><.icon name="hero-chat-bubble-left-right" class="size-4" />Open team chat</.link>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
