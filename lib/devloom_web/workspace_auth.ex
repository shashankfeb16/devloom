defmodule DevloomWeb.WorkspaceAuth do
  @moduledoc "Loads an authorized workspace and rechecks access for connected sessions."
  import Phoenix.Component
  import Phoenix.LiveView

  alias Devloom.{Meetings, WorkspacePresence, Workspaces}

  def on_mount(:ensure_member, _params, _session, %{view: DevloomWeb.WorkspaceLive} = socket),
    do: {:cont, socket}

  def on_mount(:ensure_member, %{"workspace_id" => id}, _session, socket) do
    case Workspaces.fetch_scope(socket.assigns.current_scope, id) do
      {:ok, scope} ->
        if connected?(socket) do
          Workspaces.subscribe(scope)
          WorkspacePresence.track(scope)
          if Meetings.configured?(), do: Meetings.subscribe(scope)
        end

        {:cont,
         socket
         |> assign(
           current_scope: scope,
           workspace: scope.workspace,
           active_meeting: Meetings.active(scope)
         )
         |> attach_hook(:workspace_event_access, :handle_event, fn _event, _params, socket ->
           recheck_access(socket)
         end)
         |> attach_hook(:workspace_message_access, :handle_info, fn message, socket ->
           handle_workspace_message(message, socket)
         end)}

      {:error, _reason} ->
        {:halt, deny_access(socket)}
    end
  end

  defp handle_workspace_message({:meeting_changed, _id}, socket) do
    case recheck_access(socket) do
      {:cont, socket} ->
        meeting = Meetings.active(socket.assigns.current_scope)
        {:halt, assign(socket, :active_meeting, meeting)}

      {:halt, socket} ->
        {:halt, socket}
    end
  end

  defp handle_workspace_message(_message, socket), do: recheck_access(socket)

  defp recheck_access(socket) do
    case Workspaces.fetch_scope(socket.assigns.current_scope, socket.assigns.workspace.id) do
      {:ok, scope} ->
        {:cont, assign(socket, current_scope: scope, workspace: scope.workspace)}

      {:error, _reason} ->
        {:halt, deny_access(socket)}
    end
  end

  defp deny_access(socket) do
    WorkspacePresence.untrack(socket.assigns.current_scope)

    socket
    |> put_flash(:error, "This workspace is not available to your account.")
    |> push_navigate(to: "/workspaces")
  end
end
