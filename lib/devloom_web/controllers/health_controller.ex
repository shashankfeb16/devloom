defmodule DevloomWeb.HealthController do
  use DevloomWeb, :controller

  def show(conn, _params) do
    case Devloom.Health.check() do
      :ok ->
        json(conn, %{status: "ok", database: "connected"})

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable", database: "disconnected"})
    end
  end
end
