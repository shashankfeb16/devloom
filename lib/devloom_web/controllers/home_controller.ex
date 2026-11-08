defmodule DevloomWeb.HomeController do
  use DevloomWeb, :controller

  def index(conn, _params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/workspaces")
    else
      redirect(conn, to: ~p"/users/log_in")
    end
  end
end
