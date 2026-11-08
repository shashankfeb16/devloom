defmodule DevloomWeb.WorkspaceAuth do
  @moduledoc "Loads an authorized workspace and rechecks access for connected sessions."
  import Phoenix.Component
  import Phoenix.LiveView

  alias Devloom.Workspaces

  def on_mount(:ensure_member, %{"workspace_id" => id}, _session, socket) do
    case Workspaces.fetch_scope(socket.assigns.current_scope, id) do
      {:ok, scope} ->
        if connected?(socket), do: Workspaces.subscribe(scope)

        {:cont,
         socket
         |> assign(current_scope: scope, workspace: scope.workspace)
         |> attach_hook(:workspace_event_access, :handle_event, fn _event, _params, socket ->
           recheck_access(socket)
         end)
         |> attach_hook(:workspace_message_access, :handle_info, fn _message, socket ->
           recheck_access(socket)
         end)}

      {:error, _reason} ->
        {:halt, deny_access(socket)}
    end
  end

  defp recheck_access(socket) do
    case Workspaces.fetch_scope(socket.assigns.current_scope, socket.assigns.workspace.id) do
      {:ok, scope} ->
        {:cont, assign(socket, current_scope: scope, workspace: scope.workspace)}

      {:error, _reason} ->
        {:halt, deny_access(socket)}
    end
  end

  defp deny_access(socket) do
    socket
    |> put_flash(:error, "This workspace is not available to your account.")
    |> push_navigate(to: "/workspaces")
  end
end
