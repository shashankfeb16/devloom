defmodule DevloomWeb.InvitationSessionTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Devloom.AccountsFixtures
  import Ecto.Query

  alias Devloom.{Accounts, Repo, Workspaces}
  alias Devloom.Accounts.{Scope, UserToken}

  setup %{conn: conn} do
    %{scope: owner_scope, workspace: workspace} = setup_workspace(conn)
    invitee = user_fixture(%{name: "Sam"})
    {:ok, _invitation, token} = Workspaces.create_invitation(owner_scope, %{email: invitee.email})
    conn = conn |> recycle() |> log_in_user(invitee)

    %{
      conn: conn,
      invitee_scope: Scope.for_user(invitee),
      workspace: workspace,
      invitation_token: token,
      session_token: get_session(conn, :user_token)
    }
  end

  test "revoking a session prevents an already-open public invitation from being accepted", %{
    conn: conn,
    invitee_scope: invitee_scope,
    workspace: workspace,
    invitation_token: invitation_token,
    session_token: session_token
  } do
    {:ok, view, _html} = live(conn, ~p"/invitations/#{invitation_token}")
    assert has_element?(view, "#accept-invitation")
    Accounts.delete_user_session_token(session_token)

    view |> element("#accept-invitation") |> render_click()

    assert_redirect(view, ~p"/users/log_in")
    assert Workspaces.fetch_scope(invitee_scope, workspace.id) == {:error, :not_found}
    assert {:ok, invitation} = Workspaces.get_invitation(invitation_token)
    assert invitation.accepted_at == nil
  end

  test "expired sessions cannot accept an invitation from a stale page", %{
    conn: conn,
    invitee_scope: invitee_scope,
    workspace: workspace,
    invitation_token: invitation_token,
    session_token: session_token
  } do
    {:ok, view, _html} = live(conn, ~p"/invitations/#{invitation_token}")
    assert has_element?(view, "#accept-invitation")

    hash = :crypto.hash(:sha256, session_token)
    expired_at = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

    Repo.update_all(from(token in UserToken, where: token.token == ^hash),
      set: [inserted_at: expired_at]
    )

    view |> element("#accept-invitation") |> render_click()

    assert_redirect(view, ~p"/users/log_in")
    assert Workspaces.fetch_scope(invitee_scope, workspace.id) == {:error, :not_found}
    assert {:ok, invitation} = Workspaces.get_invitation(invitation_token)
    assert invitation.accepted_at == nil
  end

  test "a revoked session also halts incoming messages on a public invitation view", %{
    conn: conn,
    invitation_token: invitation_token,
    session_token: session_token
  } do
    {:ok, view, _html} = live(conn, ~p"/invitations/#{invitation_token}")
    Accounts.delete_user_session_token(session_token)

    send(view.pid, {:account_session_probe, :must_halt_before_live_view})

    assert_redirect(view, ~p"/users/log_in")
  end
end
