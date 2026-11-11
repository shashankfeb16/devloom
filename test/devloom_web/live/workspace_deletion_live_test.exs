defmodule DevloomWeb.WorkspaceDeletionLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Devloom.AccountsFixtures

  alias Devloom.Accounts.Scope
  alias Devloom.{Repo, Workspaces}
  alias Devloom.Workspaces.Workspace
  alias DevloomWeb.Presence

  setup %{conn: conn}, do: setup_workspace(conn)

  test "owners can review and cancel deletion without losing their workspace", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces")

    open_confirmation(view, workspace)

    assert has_element?(view, "#delete-workspace-confirmation[role='dialog']")
    assert has_element?(view, "#delete-workspace-name[required]")
    assert has_element?(view, "#confirm-delete-workspace")
    assert {:ok, _scope} = Workspaces.fetch_scope(scope, workspace.id)

    view |> element("#cancel-delete-workspace") |> render_click()

    refute has_element?(view, "#delete-workspace-confirmation")
    assert has_element?(view, "#workspace-#{workspace.id}")
    assert {:ok, _scope} = Workspaces.fetch_scope(scope, workspace.id)
  end

  test "deletion requires the exact workspace name even when browser validation is bypassed", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces")
    open_confirmation(view, workspace)

    for name <- ["", String.downcase(workspace.name), "Another workspace"] do
      view |> form("#workspace-delete-form", deletion: %{name: name}) |> render_submit()

      assert has_element?(view, "#workspace-delete-form")
      assert has_element?(view, "#workspace-#{workspace.id}")
      assert Repo.get(Workspace, workspace.id)
    end
  end

  test "deleting the last workspace removes its card and shows the empty directory", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces")
    open_confirmation(view, workspace)
    confirm_deletion(view, workspace)

    assert has_element?(view, "#workspaces-page")
    refute has_element?(view, "#workspace-#{workspace.id}")
    refute has_element?(view, "#delete-workspace-confirmation")
    assert has_element?(view, "#workspaces-empty")
    assert has_element?(view, "#workspace-count", "0 workspaces")
    assert has_element?(view, "#flash-info")
    assert {:error, :not_found} = Workspaces.fetch_scope(scope, workspace.id)
  end

  test "deleting a workspace keeps the account's other workspace available", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, other} = Workspaces.create_workspace(scope, %{name: "Keep this team"})
    {:ok, view, _html} = live(conn, ~p"/workspaces")
    assert has_element?(view, "#workspace-count", "2 workspaces")

    open_confirmation(view, workspace)
    confirm_deletion(view, workspace)

    refute has_element?(view, "#workspace-#{workspace.id}")
    assert has_element?(view, "#workspace-#{other.id}")
    assert has_element?(view, "#open-workspace-#{other.id}")
    assert has_element?(view, "#workspace-count", "1 workspace")
    refute has_element?(view, "#workspaces-empty")
    assert {:ok, _scope} = Workspaces.fetch_scope(scope, other.id)
  end

  test "admins can see and use workspace deletion", %{scope: scope, workspace: workspace} do
    admin = add_member(scope)
    set_role(admin.scope, :admin)
    {:ok, view, _html} = live(admin.conn, ~p"/workspaces")

    assert has_element?(view, "#workspace-#{workspace.id} .workspace-role", "Admin")
    open_confirmation(view, workspace)
    confirm_deletion(view, workspace)

    refute has_element?(view, "#workspace-#{workspace.id}")
    assert has_element?(view, "#workspaces-empty")
    refute Repo.get(Workspace, workspace.id)
  end

  test "members and outsiders cannot forge workspace deletion events", %{
    scope: scope,
    workspace: workspace
  } do
    member = add_member(scope)
    outsider_conn = log_in_user(build_conn(), user_fixture())

    for conn <- [member.conn, outsider_conn] do
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      refute has_element?(view, "#delete-workspace-#{workspace.id}")
      render_click(view, "delete_workspace", %{"id" => to_string(workspace.id)})
      refute has_element?(view, "#delete-workspace-confirmation")

      render_submit(view, "confirm_delete_workspace", %{
        "deletion" => %{"name" => workspace.name},
        "id" => to_string(workspace.id)
      })

      assert Repo.get(Workspace, workspace.id)
    end
  end

  test "a forged confirmation cannot skip selecting a workspace", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces")

    render_submit(view, "confirm_delete_workspace", %{
      "deletion" => %{"name" => workspace.name},
      "id" => to_string(workspace.id)
    })

    assert has_element?(view, "#workspace-#{workspace.id}")
    refute has_element?(view, "#delete-workspace-confirmation")
    assert Repo.get(Workspace, workspace.id)
  end

  test "permission is rechecked if an owner is demoted after opening confirmation", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces")
    open_confirmation(view, workspace)
    set_role(scope, :member)

    confirm_deletion(view, workspace)

    assert Repo.get(Workspace, workspace.id)
    assert has_element?(view, "#flash-error")
  end

  test "permission is rechecked if an admin is removed after opening confirmation", %{
    scope: scope,
    workspace: workspace
  } do
    admin = add_member(scope)
    set_role(admin.scope, :admin)
    {:ok, view, _html} = live(admin.conn, ~p"/workspaces")
    open_confirmation(view, workspace)
    Repo.delete!(admin.scope.membership)

    confirm_deletion(view, workspace)

    assert Repo.get(Workspace, workspace.id)
    assert has_element?(view, "#flash-error")
  end

  test "a workspace deleted in another session is handled when confirmation is submitted", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces")
    open_confirmation(view, workspace)
    assert {:ok, _workspace} = Workspaces.delete_workspace(scope)

    confirm_deletion(view, workspace)

    assert has_element?(view, "#workspaces-page")
    refute has_element?(view, "#workspace-#{workspace.id}")
    refute has_element?(view, "#delete-workspace-confirmation")
    assert has_element?(view, "#workspaces-empty")
  end

  test "deletion closes every connected workspace page and prevents reopening it", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    on_exit(fn ->
      for pid <- Presence.fetchers_pids() do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      end
    end)

    member = add_member(scope)

    paths = [
      ~p"/workspaces/#{workspace.id}/board",
      ~p"/workspaces/#{workspace.id}/chat",
      ~p"/workspaces/#{workspace.id}/chat/direct/#{member.user.id}",
      ~p"/workspaces/#{workspace.id}/members"
    ]

    views =
      for path <- paths do
        {:ok, view, _html} = live(conn, path)
        view
      end

    {:ok, member_board, _html} =
      live(member.conn, ~p"/workspaces/#{workspace.id}/board")

    assert {:ok, _workspace} = Workspaces.delete_workspace(scope)

    for view <- [member_board | views], do: assert_redirect(view, ~p"/workspaces")

    for path <- paths do
      assert {:error, {:live_redirect, %{to: "/workspaces"}}} = live(conn, path)
    end
  end

  defp open_confirmation(view, workspace) do
    view |> element("#delete-workspace-#{workspace.id}") |> render_click()
  end

  defp confirm_deletion(view, workspace) do
    view
    |> form("#workspace-delete-form", deletion: %{name: workspace.name})
    |> render_submit()
  end

  defp add_member(scope) do
    user = user_fixture()
    {:ok, _invitation, token} = Workspaces.create_invitation(scope, %{email: user.email})
    {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    %{scope: scope, user: user, conn: log_in_user(build_conn(), user)}
  end

  defp set_role(scope, role) do
    scope.membership |> Ecto.Changeset.change(role: role) |> Repo.update!()
  end
end
