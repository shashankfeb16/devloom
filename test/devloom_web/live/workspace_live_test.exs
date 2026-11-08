defmodule DevloomWeb.WorkspaceLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Devloom.AccountsFixtures

  alias Devloom.Accounts.Scope
  alias Devloom.Workspaces

  setup %{conn: conn} do
    setup_workspace(conn)
  end

  test "workspace pages require sign in and the directory only shows memberships", %{
    conn: conn,
    workspace: workspace
  } do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(build_conn(), ~p"/workspaces")

    other = user_fixture(%{name: "Other owner"})

    {:ok, foreign_workspace} =
      Workspaces.create_workspace(Scope.for_user(other), %{name: "Other team"})

    {:ok, view, _html} = live(conn, ~p"/workspaces")

    assert has_element?(view, "#workspaces-page")
    assert has_element?(view, "#workspace-#{workspace.id}")
    refute has_element?(view, "#workspace-#{foreign_workspace.id}")

    assert has_element?(
             view,
             "#open-workspace-#{workspace.id}[href='/workspaces/#{workspace.id}/board']"
           )
  end

  test "creating a workspace validates its name and opens a separate empty board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces")

    view |> form("#workspace-create-form", workspace: %{name: " "}) |> render_submit()
    assert has_element?(view, "#workspace-create-form")

    view |> form("#workspace-create-form", workspace: %{name: "Product team"}) |> render_submit()

    [workspace | _] =
      conn.assigns.test_scope
      |> Workspaces.list_workspaces()
      |> Enum.filter(&(&1.name == "Product team"))

    assert_redirect(view, ~p"/workspaces/#{workspace.id}/board")
  end

  test "owners create invitation links that the invited account can accept once", %{
    conn: conn,
    workspace: workspace,
    scope: owner_scope
  } do
    invited = user_fixture(%{name: "Jamie"})
    {:ok, members, _html} = live(conn, ~p"/workspaces/#{workspace.id}/members")

    members
    |> form("#invite-member-form", invitation: %{email: invited.email})
    |> render_submit()

    assert has_element?(members, "#invitation-link[readonly]")
    [invitation] = Workspaces.list_pending_invitations(owner_scope)
    assert has_element?(members, "#invitation-#{invitation.id}")
    token = invitation_token(members)

    invited_conn = log_in_user(build_conn(), invited)
    {:ok, invitation_view, _html} = live(invited_conn, ~p"/invitations/#{token}")
    assert has_element?(invitation_view, "#accept-invitation")
    invitation_view |> element("#accept-invitation") |> render_click()
    assert_redirect(invitation_view, ~p"/workspaces/#{workspace.id}/board")

    assert {:ok, member_scope} = Workspaces.fetch_scope(Scope.for_user(invited), workspace.id)
    assert member_scope.membership.role == :member
    assert has_element?(members, "#member-#{member_scope.membership.id}")
    refute has_element?(members, "#invitation-#{invitation.id}")

    {:ok, used_view, _html} = live(invited_conn, ~p"/invitations/#{token}")
    assert has_element?(used_view, "#invitation-invalid")
    refute has_element?(used_view, "#accept-invitation")
  end

  test "anonymous invitation views preserve the return path without exposing workspace details",
       %{
         scope: scope
       } do
    {:ok, _invitation, token} =
      Workspaces.create_invitation(scope, %{email: "new-member@example.com"})

    {:ok, view, _html} = live(build_conn(), ~p"/invitations/#{token}")

    assert has_element?(view, "#invitation-sign-in[href]")
    assert has_element?(view, "#invitation-sign-up[href]")

    assert attribute(view, "#invitation-sign-in", "href") ==
             ~p"/users/log_in?#{[return_to: "/invitations/#{token}"]}"

    refute has_element?(view, "#accept-invitation")
    refute has_element?(view, "#workspace-invitation-page", scope.workspace.name)
    refute has_element?(view, "#workspace-invitation-page", "new-member@example.com")
  end

  test "wrong-account and revoked invitations never grant access", %{conn: conn, scope: scope} do
    invited = user_fixture(%{name: "Jamie"})
    {:ok, invitation, token} = Workspaces.create_invitation(scope, %{email: invited.email})
    {:ok, wrong_account, _html} = live(conn, ~p"/invitations/#{token}")

    assert has_element?(wrong_account, "#invitation-wrong-account")
    refute has_element?(wrong_account, "#accept-invitation")
    assert has_element?(wrong_account, "#invitation-switch-account")

    {:ok, owner_members, _html} = live(conn, ~p"/workspaces/#{scope.workspace.id}/members")
    owner_members |> element("#revoke-invitation-#{invitation.id}") |> render_click()
    refute has_element?(owner_members, "#invitation-#{invitation.id}")

    {:ok, revoked, _html} = live(log_in_user(build_conn(), invited), ~p"/invitations/#{token}")
    assert has_element?(revoked, "#invitation-invalid")

    assert {:error, :not_found} =
             Workspaces.fetch_scope(Scope.for_user(invited), scope.workspace.id)
  end

  test "members cannot manage membership, and owners remove access with confirmation", %{
    conn: conn,
    scope: scope
  } do
    invited = user_fixture(%{name: "Jamie"})
    {:ok, _invitation, token} = Workspaces.create_invitation(scope, %{email: invited.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(invited), token)
    {:ok, member_scope} = Workspaces.fetch_scope(Scope.for_user(invited), scope.workspace.id)
    member_conn = log_in_user(build_conn(), invited)
    {:ok, member_view, _html} = live(member_conn, ~p"/workspaces/#{scope.workspace.id}/members")

    refute has_element?(member_view, "#invite-member-form")
    refute has_element?(member_view, "#remove-member-#{scope.membership.id}")
    refute has_element?(member_view, "#workspace-invitations")

    {:ok, owner_view, _html} = live(conn, ~p"/workspaces/#{scope.workspace.id}/members")
    owner_view |> element("#remove-member-#{member_scope.membership.id}") |> render_click()
    assert has_element?(owner_view, "#remove-member-confirmation")
    assert {:ok, _scope} = Workspaces.fetch_scope(Scope.for_user(invited), scope.workspace.id)

    owner_view |> element("#confirm-remove-member") |> render_click()
    refute has_element?(owner_view, "#member-#{member_scope.membership.id}")

    assert {:error, :not_found} =
             Workspaces.fetch_scope(Scope.for_user(invited), scope.workspace.id)

    assert_redirect(member_view, ~p"/workspaces")
  end

  test "a foreign workspace URL is rejected before rendering its members", %{conn: conn} do
    owner = user_fixture(%{name: "Other owner"})
    {:ok, foreign} = Workspaces.create_workspace(Scope.for_user(owner), %{name: "Private team"})

    assert {:error, {:live_redirect, %{to: "/workspaces"}}} =
             live(conn, ~p"/workspaces/#{foreign.id}/members")
  end

  defp invitation_token(view) do
    view
    |> attribute("#invitation-link", "value")
    |> URI.parse()
    |> Map.fetch!(:path)
    |> String.replace_prefix("/invitations/", "")
  end

  defp attribute(view, selector, key) do
    [{_tag, attrs, _children}] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.to_tree()

    {_key, value} = List.keyfind(attrs, key, 0)
    value
  end
end
