defmodule DevloomWeb.UserAuth do
  @moduledoc "Session lifecycle and authentication for HTTP and LiveView requests."
  use DevloomWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller

  alias Devloom.Accounts
  alias Devloom.Accounts.Scope
  alias Phoenix.Component
  alias Phoenix.LiveView

  def fetch_current_scope_for_user(conn, _opts) do
    user = conn |> get_session(:user_token) |> Accounts.get_user_by_session_token()
    assign(conn, :current_scope, Scope.for_user(user))
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> maybe_store_invitation_return_to()
      |> put_flash(:error, "Sign in to continue to your workspace.")
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  def log_in_user(conn, user, params \\ %{}) do
    destination =
      safe_return_to(params["return_to"]) || safe_return_to(get_session(conn, :user_return_to)) ||
        ~p"/workspaces"

    revoke_current_session(conn)
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, session_topic(token))
    |> redirect(to: destination)
  end

  def log_out_user(conn) do
    revoke_current_session(conn)

    conn
    |> renew_session()
    |> put_flash(:info, "You have signed out.")
    |> redirect(to: ~p"/users/log_in")
  end

  def safe_return_to(path) when is_binary(path) do
    if Regex.match?(~r"\A/invitations/[A-Za-z0-9_-]{20,128}\z", path), do: path
  end

  def safe_return_to(_), do: nil

  def remember_return_to(conn, params) do
    destination = safe_return_to(params["return_to"]) || get_session(conn, :user_return_to)

    if destination = safe_return_to(destination) do
      {put_session(conn, :user_return_to, destination), destination}
    else
      {conn, nil}
    end
  end

  def on_mount(:mount_current_scope, _params, session, socket) do
    socket = mount_scope(socket, session)
    socket = if socket.assigns.current_scope, do: verify_live_hooks(socket), else: socket
    {:cont, socket}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, verify_live_hooks(socket)}
    else
      {:halt, sign_in_redirect(socket)}
    end
  end

  defp verify_live_hooks(socket) do
    socket
    |> LiveView.attach_hook(:verify_user_session_event, :handle_event, fn _, _, socket ->
      verify_live_session(socket)
    end)
    |> LiveView.attach_hook(:verify_user_session_info, :handle_info, fn _, socket ->
      verify_live_session(socket)
    end)
  end

  defp mount_scope(socket, session) do
    token = session["user_token"]
    user = Accounts.get_user_by_session_token(token)

    socket
    |> Component.assign(:current_scope, Scope.for_user(user))
    |> Component.assign(:session_token, token)
  end

  defp verify_live_session(socket) do
    case Accounts.get_user_by_session_token(socket.assigns.session_token) do
      nil ->
        {:halt, sign_in_redirect(socket)}

      user ->
        {:cont,
         Component.assign(socket, :current_scope, %{socket.assigns.current_scope | user: user})}
    end
  end

  defp sign_in_redirect(socket) do
    Devloom.WorkspacePresence.untrack(socket.assigns[:current_scope])

    socket
    |> LiveView.put_flash(:error, "Your session has ended. Sign in to continue.")
    |> LiveView.redirect(to: ~p"/users/log_in")
  end

  defp maybe_store_invitation_return_to(%{method: "GET"} = conn) do
    case safe_return_to(current_path(conn)) do
      nil -> conn
      path -> put_session(conn, :user_return_to, path)
    end
  end

  defp maybe_store_invitation_return_to(conn), do: conn

  defp revoke_current_session(conn) do
    if token = get_session(conn, :user_token) do
      Accounts.delete_user_session_token(token)
      DevloomWeb.Endpoint.broadcast(session_topic(token), "disconnect", %{})
    end

    :ok
  end

  defp renew_session(conn) do
    delete_csrf_token()
    conn |> configure_session(renew: true) |> clear_session()
  end

  defp session_topic(token), do: "users_sessions:" <> Base.url_encode64(token, padding: false)
end
