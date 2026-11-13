defmodule Devloom.WhiteboardsTest do
  use Devloom.DataCase

  import Devloom.AccountsFixtures

  alias Devloom.Accounts.Scope
  alias Devloom.Whiteboards.Whiteboard
  alias Devloom.{Whiteboards, Workspaces}

  setup do
    %{scope: workspace_scope("Design team")}
  end

  test "first visit creates one empty whiteboard and later visits preserve it", %{scope: scope} do
    refute Repo.exists?(
             from whiteboard in Whiteboard, where: whiteboard.workspace_id == ^scope.workspace.id
           )

    whiteboard = Whiteboards.get_whiteboard!(scope)
    assert whiteboard.workspace_id == scope.workspace.id
    assert whiteboard.name == "Team whiteboard"
    assert whiteboard.scene == %{"elements" => []}
    assert whiteboard.revision == 1
    assert Whiteboards.get_whiteboard!(scope).id == whiteboard.id
    assert Repo.aggregate(Whiteboard, :count) == 1
  end

  test "all drawing types and styles survive a save and reload", %{scope: scope} do
    whiteboard = Whiteboards.get_whiteboard!(scope)

    elements =
      for type <- ~w(rectangle ellipse diamond line arrow freedraw text note) do
        element(type, %{
          "type" => type,
          "stroke" => "#9C36B5",
          "fill" => "#e5dbff",
          "strokeWidth" => 4,
          "opacity" => 65,
          "strokeStyle" => "dashed",
          "roughness" => 2,
          "roundness" => false,
          "text" => "Ideas <script>are text</script>\nand another line",
          "points" => [[0, 30], [10.5, 20], [40, 0]]
        })
      end

    assert {:ok, saved} =
             Whiteboards.save_scene(scope, whiteboard.id, %{"elements" => elements}, 1)

    assert saved.scene == %{"elements" => elements}
    assert saved.revision == 2
    assert Whiteboards.get_whiteboard!(scope) == saved

    assert {:ok, cleared} = Whiteboards.save_scene(scope, whiteboard.id, %{"elements" => []}, 2)
    assert cleared.scene == %{"elements" => []}
    assert cleared.revision == 3
    assert Whiteboards.get_whiteboard!(scope) == cleared
  end

  test "normalizes defaults and ignores unrecognized scene attributes", %{scope: scope} do
    whiteboard = Whiteboards.get_whiteboard!(scope)

    minimal = %{
      "id" => "shape",
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 30,
      "height" => 40
    }

    assert {:ok, saved} =
             Whiteboards.save_scene(
               scope,
               whiteboard.id,
               %{
                 "elements" => [Map.put(minimal, "workspace_id", 999)],
                 "workspace_id" => 999
               },
               1
             )

    assert Map.keys(saved.scene) == ["elements"]
    [shape] = saved.scene["elements"]
    assert shape["strokeWidth"] == 2
    assert shape["fill"] == "transparent"
    refute Map.has_key?(shape, "workspace_id")
    assert saved.workspace_id == scope.workspace.id
  end

  test "lines and arrows retain their direction when drawn toward the upper left", %{scope: scope} do
    whiteboard = Whiteboards.get_whiteboard!(scope)

    elements =
      for type <- ~w(line arrow) do
        element(type, %{"type" => type, "width" => -150, "height" => -80})
      end

    assert {:ok, saved} =
             Whiteboards.save_scene(scope, whiteboard.id, %{"elements" => elements}, 1)

    assert saved.scene["elements"] == elements
  end

  test "a stale save cannot overwrite the latest scene or publish a change", %{scope: scope} do
    whiteboard = Whiteboards.get_whiteboard!(scope)
    assert :ok = Whiteboards.subscribe(scope)
    scene = %{"elements" => [element("first")]}
    assert {:ok, current} = Whiteboards.save_scene(scope, whiteboard.id, scene, 1)
    assert_receive {:whiteboard_updated, ^current}

    assert {:error, :stale} =
             Whiteboards.save_scene(scope, whiteboard.id, %{"elements" => [element("stale")]}, 1)

    assert Whiteboards.get_whiteboard!(scope) == current
    refute_received {:whiteboard_updated, _}
  end

  test "renaming preserves the scene, validates names, and publishes only saved changes", %{
    scope: scope
  } do
    whiteboard = Whiteboards.get_whiteboard!(scope)

    assert {:ok, drawn} =
             Whiteboards.save_scene(
               scope,
               whiteboard.id,
               %{"elements" => [element("drawing")]},
               1
             )

    assert :ok = Whiteboards.subscribe(scope)

    assert {:ok, renamed} =
             Whiteboards.rename_whiteboard(scope, whiteboard.id, "  Sprint ideas  ")

    assert renamed.name == "Sprint ideas"
    assert renamed.scene == drawn.scene
    assert renamed.revision == drawn.revision + 1
    assert_receive {:whiteboard_updated, ^renamed}

    for invalid <- ["", "  ", nil, String.duplicate("a", 101)] do
      assert {:error, %Ecto.Changeset{}} =
               Whiteboards.rename_whiteboard(scope, whiteboard.id, invalid)
    end

    assert Whiteboards.get_whiteboard!(scope) == renamed
    refute_received {:whiteboard_updated, _}
  end

  test "workspace boundaries apply to reads, saves, renames and subscriptions", %{scope: scope} do
    whiteboard = Whiteboards.get_whiteboard!(scope)
    outsider = workspace_scope("Other team")
    other = Whiteboards.get_whiteboard!(outsider)
    forged = %{outsider | workspace: scope.workspace, membership: scope.membership}
    scene = %{"elements" => []}

    assert {:error, :not_found} = Whiteboards.save_scene(scope, other.id, scene, 1)
    assert {:error, :not_found} = Whiteboards.rename_whiteboard(scope, other.id, "Guessing IDs")

    for unauthorized <- [forged, Scope.for_user(scope.user), nil] do
      assert_raise Ecto.NoResultsError, fn -> Whiteboards.get_whiteboard!(unauthorized) end

      assert {:error, :unauthorized} =
               Whiteboards.save_scene(unauthorized, whiteboard.id, scene, 1)

      assert {:error, :unauthorized} =
               Whiteboards.rename_whiteboard(unauthorized, whiteboard.id, "No access")

      assert {:error, :unauthorized} = Whiteboards.subscribe(unauthorized)
    end

    assert Whiteboards.get_whiteboard!(scope) == whiteboard
    assert Whiteboards.get_whiteboard!(outsider) == other
  end

  test "members can share the canvas and removed members lose access even with cached scopes", %{
    scope: owner
  } do
    member = join_workspace(owner, user_fixture())
    whiteboard = Whiteboards.get_whiteboard!(member)
    assert whiteboard.id == Whiteboards.get_whiteboard!(owner).id
    assert :ok = Whiteboards.subscribe(owner)

    assert {:ok, saved} =
             Whiteboards.save_scene(
               member,
               whiteboard.id,
               %{"elements" => [element("member")]},
               1
             )

    assert_receive {:whiteboard_updated, ^saved}

    assert {:ok, _} = Workspaces.remove_member(owner, member.membership.id)
    assert_raise Ecto.NoResultsError, fn -> Whiteboards.get_whiteboard!(member) end

    assert {:error, :unauthorized} =
             Whiteboards.save_scene(member, whiteboard.id, %{"elements" => []}, 2)

    assert {:error, :unauthorized} =
             Whiteboards.rename_whiteboard(member, whiteboard.id, "Removed")

    assert {:error, :unauthorized} = Whiteboards.subscribe(member)
    assert Whiteboards.get_whiteboard!(owner) == saved
    refute_received {:whiteboard_updated, _}
  end

  test "invalid scenes and invalid IDs never change the canvas", %{scope: scope} do
    whiteboard = Whiteboards.get_whiteboard!(scope)
    assert :ok = Whiteboards.subscribe(scope)
    valid = element("shape")

    invalid_scenes = [
      nil,
      %{},
      %{"elements" => %{}},
      %{"elements" => [nil]},
      %{"elements" => [Map.delete(valid, "id")]},
      %{"elements" => [valid, valid]},
      %{"elements" => [Map.put(valid, "type", "script")]},
      %{"elements" => [Map.put(valid, "x", "1")]},
      %{"elements" => [Map.put(valid, "y", 1_000_001)]},
      %{"elements" => [Map.put(valid, "width", -1)]},
      %{"elements" => [Map.put(valid, "stroke", "url(https://example.com)")]},
      %{"elements" => [Map.put(valid, "fill", "red")]},
      %{"elements" => [Map.put(valid, "strokeWidth", 100)]},
      %{"elements" => [Map.put(valid, "opacity", 101)]},
      %{"elements" => [Map.put(valid, "strokeStyle", "invented")]},
      %{"elements" => [Map.put(valid, "roughness", 3)]},
      %{"elements" => [Map.put(valid, "roundness", "yes")]},
      %{"elements" => [Map.put(valid, "text", String.duplicate("a", 10_001))]},
      %{"elements" => [Map.put(valid, "points", [[0, "bad"]])]},
      %{"elements" => [Map.put(valid, "type", "freedraw")]},
      %{"elements" => [Map.put(valid, "points", List.duplicate([0, 0], 10_001))]},
      %{"elements" => Enum.map(1..1_001, &element(Integer.to_string(&1)))},
      %{
        "elements" =>
          Enum.map(
            1..201,
            &element(Integer.to_string(&1), %{"text" => String.duplicate("a", 10_000)})
          )
      }
    ]

    for invalid <- invalid_scenes do
      assert {:error, :invalid_scene} = Whiteboards.save_scene(scope, whiteboard.id, invalid, 1)
    end

    for invalid_id <- [nil, "not-an-id", -1, 0, String.duplicate("9", 100)] do
      assert {:error, :not_found} =
               Whiteboards.save_scene(scope, invalid_id, %{"elements" => []}, 1)

      assert {:error, :not_found} = Whiteboards.rename_whiteboard(scope, invalid_id, "Invalid")

      assert {:error, :not_found} =
               Whiteboards.save_scene(scope, whiteboard.id, %{"elements" => []}, invalid_id)
    end

    assert Whiteboards.get_whiteboard!(scope) == whiteboard
    refute_received {:whiteboard_updated, _}
  end

  test "updates publish only within their workspace", %{scope: scope} do
    other_scope = workspace_scope("Other team")
    whiteboard = Whiteboards.get_whiteboard!(other_scope)
    assert :ok = Whiteboards.subscribe(scope)

    assert {:ok, _} =
             Whiteboards.save_scene(
               other_scope,
               whiteboard.id,
               %{"elements" => [element("other")]},
               1
             )

    refute_received {:whiteboard_updated, _}
  end

  test "deleting a workspace cascades its whiteboard and invalidates cached access", %{
    scope: scope
  } do
    whiteboard = Whiteboards.get_whiteboard!(scope)
    other_scope = workspace_scope("Team to keep")
    other = Whiteboards.get_whiteboard!(other_scope)

    assert {:ok, _} = Workspaces.delete_workspace(scope)
    assert Repo.get(Whiteboard, whiteboard.id) == nil
    assert Repo.get!(Whiteboard, other.id) == other

    assert {:error, :unauthorized} =
             Whiteboards.save_scene(scope, whiteboard.id, %{"elements" => []}, 1)

    assert {:error, :unauthorized} =
             Whiteboards.rename_whiteboard(scope, whiteboard.id, "Deleted")

    assert_raise Ecto.NoResultsError, fn -> Whiteboards.get_whiteboard!(scope) end
  end

  defp workspace_scope(name) do
    user_scope = Scope.for_user(user_fixture())
    {:ok, workspace} = Workspaces.create_workspace(user_scope, %{name: name})
    {:ok, scope} = Workspaces.fetch_scope(user_scope, workspace.id)
    scope
  end

  defp join_workspace(owner, user) do
    {:ok, _invitation, token} = Workspaces.create_invitation(owner, %{email: user.email})
    {:ok, workspace} = Workspaces.accept_invitation(Scope.for_user(user), token)
    {:ok, scope} = Workspaces.fetch_scope(Scope.for_user(user), workspace.id)
    scope
  end

  defp element(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "type" => "rectangle",
        "x" => 100,
        "y" => 200,
        "width" => 150,
        "height" => 80,
        "stroke" => "#1e293b",
        "fill" => "transparent",
        "strokeWidth" => 2,
        "opacity" => 100,
        "strokeStyle" => "solid",
        "roughness" => 1,
        "roundness" => true,
        "text" => "",
        "points" => []
      },
      attrs
    )
  end
end
