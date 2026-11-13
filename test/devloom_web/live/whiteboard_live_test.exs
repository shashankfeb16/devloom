defmodule DevloomWeb.WhiteboardLiveTest do
  use DevloomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Devloom.AccountsFixtures

  alias Devloom.Accounts.Scope
  alias Devloom.{Accounts, Repo, Whiteboards, Workspaces}

  setup %{conn: conn}, do: setup_workspace(conn)

  test "whiteboards require a signed-in workspace member", %{conn: conn, workspace: workspace} do
    response = get(build_conn(), path(workspace))
    assert redirected_to(response) == "/users/log_in"

    other = setup_workspace(build_conn())

    assert {:error, {:live_redirect, %{to: "/workspaces"}}} =
             live(conn, path(other.workspace))
  end

  test "the workspace navigation opens a blank whiteboard with drawing controls", %{
    conn: conn,
    workspace: workspace,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, path(workspace))

    assert has_element?(view, "#nav-whiteboard[aria-current='page']")
    assert has_element?(view, "#mobile-nav-whiteboard")

    assert has_element?(
             view,
             "#whiteboard-canvas-hook[phx-hook='Whiteboard'][phx-update='ignore']"
           )

    assert has_element?(view, "#whiteboard-svg")

    for tool <- ~w(select hand rectangle diamond ellipse arrow line freedraw text note eraser) do
      assert has_element?(view, "#whiteboard-canvas-hook [data-tool='#{tool}']")
    end

    assert Whiteboards.get_whiteboard!(scope).scene == %{"elements" => []}
  end

  test "a saved drawing survives a new live session", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    board = Whiteboards.get_whiteboard!(scope)

    save(view, board, scene("saved-rectangle"))

    persisted = Whiteboards.get_whiteboard!(scope)
    assert persisted.revision == board.revision + 1
    assert [%{"id" => "saved-rectangle", "type" => "rectangle"}] = persisted.scene["elements"]

    {:ok, remounted, _html} = live(second_conn(conn), path(workspace))

    assert has_element?(
             remounted,
             "#whiteboard-canvas-hook[data-revision='#{persisted.revision}']"
           )

    assert Whiteboards.get_whiteboard!(scope).scene == persisted.scene
  end

  test "committed drawings are pushed to another connected canvas", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, first, _html} = live(conn, path(workspace))
    {:ok, second, _html} = live(second_conn(conn), path(workspace))
    board = Whiteboards.get_whiteboard!(scope)

    save(first, board, scene("shared-rectangle"))

    revision = board.revision + 1
    assert_push_event(second, "whiteboard:updated", %{revision: ^revision})
    assert has_element?(second, "#whiteboard-canvas-hook")
  end

  test "an outdated canvas cannot replace a newer drawing", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    stale_board = Whiteboards.get_whiteboard!(scope)

    {:ok, current} =
      Whiteboards.save_scene(scope, stale_board.id, scene("newer"), stale_board.revision)

    save(view, stale_board, scene("older"))

    persisted = Whiteboards.get_whiteboard!(scope)
    assert persisted.revision == current.revision
    assert persisted.scene == current.scene
    assert has_element?(view, "#whiteboard-canvas-hook")
  end

  test "renaming a whiteboard keeps its drawing and updates another connected session", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, first, _html} = live(conn, path(workspace))
    {:ok, second, _html} = live(second_conn(conn), path(workspace))
    board = Whiteboards.get_whiteboard!(scope)
    save(first, board, scene("keep-this-idea"))
    drawing = Whiteboards.get_whiteboard!(scope).scene

    first
    |> form("#whiteboard-name-form", whiteboard: %{name: "Architecture brainstorm"})
    |> render_submit()

    assert has_element?(first, "#whiteboard-title", "Architecture brainstorm")
    assert has_element?(second, "#whiteboard-title", "Architecture brainstorm")
    assert Whiteboards.get_whiteboard!(scope).name == "Architecture brainstorm"
    assert Whiteboards.get_whiteboard!(scope).scene == drawing

    first |> form("#whiteboard-name-form", whiteboard: %{name: ""}) |> render_submit()
    assert Whiteboards.get_whiteboard!(scope).name == "Architecture brainstorm"
    assert has_element?(first, "#flash-error")
  end

  test "invalid scenes and foreign canvas IDs do not change either drawing", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    other = setup_workspace(build_conn())
    foreign = Whiteboards.get_whiteboard!(other.scope)
    {:ok, view, _html} = live(conn, path(workspace))
    board = Whiteboards.get_whiteboard!(scope)

    save(view, board, %{"elements" => [%{"type" => "script"}]})
    save(view, foreign, scene("foreign-write"))

    assert Whiteboards.get_whiteboard!(scope).revision == board.revision
    assert Whiteboards.get_whiteboard!(scope).scene == %{"elements" => []}
    assert Whiteboards.get_whiteboard!(other.scope).revision == foreign.revision
    assert Whiteboards.get_whiteboard!(other.scope).scene == %{"elements" => []}
  end

  test "malformed canvas IDs are rejected without disconnecting the editor", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    board = Whiteboards.get_whiteboard!(scope)

    for id <- [%{"id" => board.id}, [board.id], nil] do
      render_hook(view, "save_scene", %{
        board_id: id,
        scene: scene("invalid"),
        revision: board.revision
      })

      render_hook(view, "sync_scene", %{board_id: id})
      assert has_element?(view, "#whiteboard-canvas-hook")
    end

    assert Whiteboards.get_whiteboard!(scope).revision == board.revision
    assert Whiteboards.get_whiteboard!(scope).scene == %{"elements" => []}

    save(view, board, scene("valid-after-rejection"))

    assert [%{"id" => "valid-after-rejection"}] =
             Whiteboards.get_whiteboard!(scope).scene["elements"]
  end

  test "resynchronizing reloads a committed scene even when its broadcast was missed", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    board = Whiteboards.get_whiteboard!(scope)

    # Commit without PubSub to model a change made while this canvas was disconnected.
    latest =
      board
      |> Ecto.Changeset.change(scene: scene("missed-update"), revision: board.revision + 1)
      |> Repo.update!()

    assert has_element?(view, "#whiteboard-canvas-hook[data-revision='#{board.revision}']")
    render_hook(view, "sync_scene", %{board_id: board.id})

    assert has_element?(view, "#whiteboard-canvas-hook[data-revision='#{latest.revision}']")
    assert has_element?(view, "#whiteboard-canvas-hook[data-scene*='missed-update']")
    assert Whiteboards.get_whiteboard!(scope).revision == latest.revision
  end

  test "removed members lose access to an already connected canvas", %{
    scope: owner_scope,
    workspace: workspace
  } do
    member = user_fixture(%{name: "Whiteboard teammate"})
    {:ok, _invitation, token} = Workspaces.create_invitation(owner_scope, %{email: member.email})
    {:ok, _workspace} = Workspaces.accept_invitation(Scope.for_user(member), token)
    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, path(workspace))
    membership = Enum.find(Workspaces.list_members(owner_scope), &(&1.user_id == member.id))

    assert {:ok, _membership} = Workspaces.remove_member(owner_scope, membership.id)
    assert_redirect(view, "/workspaces")
  end

  test "session revocation prevents saves from an already connected canvas", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    board = Whiteboards.get_whiteboard!(scope)
    :ok = Accounts.delete_user_session_token(get_session(conn, :user_token))

    save(view, board, scene("revoked-write"))

    assert_redirect(view, "/users/log_in")
    assert Whiteboards.get_whiteboard!(scope).revision == board.revision
  end

  test "workspace deletion closes its connected whiteboard", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))

    assert {:ok, _workspace} = Workspaces.delete_workspace(scope)
    assert_redirect(view, "/workspaces")
  end

  defp save(view, board, scene) do
    render_hook(view, "save_scene", %{
      board_id: board.id,
      scene: scene,
      revision: board.revision
    })
  end

  defp scene(id) do
    %{
      "elements" => [
        %{
          "id" => id,
          "type" => "rectangle",
          "x" => 100,
          "y" => 80,
          "width" => 200,
          "height" => 120
        }
      ]
    }
  end

  defp path(workspace), do: "/workspaces/#{workspace.id}/whiteboard"
end
