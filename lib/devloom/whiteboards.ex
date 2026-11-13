defmodule Devloom.Whiteboards do
  @moduledoc "Persistent workspace whiteboards with membership and revision checks."
  import Ecto.Query

  alias Devloom.Accounts.{Scope, User}
  alias Devloom.{Repo, Workspaces}
  alias Devloom.Whiteboards.{Scene, Whiteboard}
  alias Devloom.Workspaces.Workspace

  @doc "Loads the workspace canvas, creating an empty one on its first visit."
  def get_whiteboard!(scope) do
    case authorized_transaction(scope, fn workspace ->
           Repo.get_by(Whiteboard, workspace_id: workspace.id) ||
             Repo.insert!(%Whiteboard{workspace_id: workspace.id})
         end) do
      {:ok, whiteboard} -> whiteboard
      {:error, _reason} -> raise Ecto.NoResultsError, queryable: Whiteboard
    end
  end

  @doc "Saves a complete scene only if its base revision is still current."
  def save_scene(scope, board_id, scene, expected_revision) do
    with {:ok, scene} <- Scene.normalize(scene),
         {:ok, board_id} <- cast_id(board_id),
         {:ok, expected_revision} <- cast_id(expected_revision) do
      scope
      |> authorized_transaction(fn workspace ->
        whiteboard = lock_whiteboard!(workspace, board_id)

        if whiteboard.revision != expected_revision, do: Repo.rollback(:stale)

        whiteboard
        |> Ecto.Changeset.change(scene: scene, revision: whiteboard.revision + 1)
        |> Repo.update!()
      end)
      |> broadcast()
    else
      {:error, :invalid_scene} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Renames the canvas without replacing its current drawing data."
  def rename_whiteboard(scope, board_id, name) do
    with {:ok, board_id} <- cast_id(board_id) do
      scope
      |> authorized_transaction(fn workspace ->
        whiteboard = lock_whiteboard!(workspace, board_id)

        whiteboard
        |> Whiteboard.rename_changeset(name)
        |> Ecto.Changeset.put_change(:revision, whiteboard.revision + 1)
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> broadcast()
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Subscribes an authorized member to committed canvas changes."
  def subscribe(%Scope{} = scope) do
    if Workspaces.authorized_scope?(scope) do
      Phoenix.PubSub.subscribe(Devloom.PubSub, topic(scope))
    else
      {:error, :unauthorized}
    end
  end

  def subscribe(_scope), do: {:error, :unauthorized}

  def topic(%Scope{workspace: %Workspace{id: id}}), do: "workspace:#{id}:whiteboard"

  defp authorized_transaction(
         %Scope{user: %User{}, workspace: %Workspace{id: workspace_id}} = scope,
         fun
       ) do
    Repo.transaction(fn ->
      # Membership changes and workspace deletion also acquire this lock. A
      # cached scope cannot write after access has been revoked.
      workspace =
        Repo.one(
          from workspace in Workspace,
            where: workspace.id == ^workspace_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:unauthorized)

      if !Workspaces.authorized_scope?(scope), do: Repo.rollback(:unauthorized)
      fun.(workspace)
    end)
  end

  defp authorized_transaction(_scope, _fun), do: {:error, :unauthorized}

  defp lock_whiteboard!(workspace, board_id) do
    Repo.one(
      from whiteboard in Whiteboard,
        where: whiteboard.id == ^board_id and whiteboard.workspace_id == ^workspace.id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp broadcast({:ok, %Whiteboard{} = whiteboard} = result) do
    Phoenix.PubSub.broadcast(
      Devloom.PubSub,
      "workspace:#{whiteboard.workspace_id}:whiteboard",
      {:whiteboard_updated, whiteboard}
    )

    result
  end

  defp broadcast(error), do: error

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> :error
    end
  end
end
