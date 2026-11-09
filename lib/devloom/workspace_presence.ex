defmodule Devloom.WorkspacePresence do
  @moduledoc """
  Online members of a workspace, grouped across live connections.

  A member is online while at least one live view is connected to that
  workspace. Phoenix monitors each tracked process and removes its presence
  when it ends. Status is ephemeral and contains no email or session tokens.
  """
  alias Devloom.Accounts.Scope
  alias Devloom.Workspaces
  alias Devloom.Workspaces.Workspace
  alias DevloomWeb.Presence

  def subscribe(%Scope{} = scope) do
    if Workspaces.authorized_scope?(scope) do
      Phoenix.PubSub.subscribe(Devloom.PubSub, topic(scope))
    else
      {:error, :unauthorized}
    end
  end

  def subscribe(_scope), do: {:error, :unauthorized}

  def track(scope, pid \\ self())

  def track(%Scope{} = scope, pid) when is_pid(pid) do
    if Workspaces.authorized_scope?(scope) do
      Presence.track(pid, topic(scope), to_string(scope.user.id), %{})
    else
      {:error, :unauthorized}
    end
  end

  def track(_scope, _pid), do: {:error, :unauthorized}

  @doc "Removes a connection, including after its workspace membership was revoked."
  def untrack(scope, pid \\ self())

  def untrack(%Scope{user: %{id: id}, workspace: %Workspace{}} = scope, pid)
      when is_pid(pid) do
    Presence.untrack(pid, topic(scope), to_string(id))
  end

  def untrack(_scope, _pid), do: :ok

  def online_user_ids(%Scope{} = scope) do
    if Workspaces.authorized_scope?(scope) do
      current_members = scope |> Workspaces.list_members() |> MapSet.new(& &1.user_id)

      scope
      |> topic()
      |> Presence.list()
      |> Map.keys()
      |> Enum.reduce(MapSet.new(), fn key, ids ->
        case Integer.parse(key) do
          {id, ""} -> MapSet.put(ids, id)
          _ -> ids
        end
      end)
      |> MapSet.intersection(current_members)
    else
      MapSet.new()
    end
  end

  def online_user_ids(_scope), do: MapSet.new()

  def topic(%Scope{workspace: %Workspace{id: id}}), do: "workspace:#{id}:presence"
end
