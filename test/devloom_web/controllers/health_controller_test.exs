defmodule DevloomWeb.HealthControllerTest do
  use DevloomWeb.ConnCase, async: true

  test "readiness confirms an actual database connection", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "database" => "connected"
           }
  end
end
