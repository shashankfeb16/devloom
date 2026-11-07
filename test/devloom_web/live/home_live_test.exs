defmodule DevloomWeb.HomeLiveTest do
  use DevloomWeb.ConnCase

  import Phoenix.LiveViewTest

  test "workspace checks its database through a LiveView interaction", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#database-status[data-status='ready']")
    assert has_element?(view, "#connection-feedback[data-check-count='0']")

    view |> element("#check-connection") |> render_click()

    assert has_element?(view, "#database-status[data-status='ready']")
    assert has_element?(view, "#connection-feedback[data-check-count='1']")
  end
end
