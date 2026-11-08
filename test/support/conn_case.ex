defmodule DevloomWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DevloomWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DevloomWeb.Endpoint

      use DevloomWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import DevloomWeb.ConnCase
    end
  end

  setup tags do
    Devloom.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def log_in_user(conn, user) do
    token = Devloom.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  def setup_workspace(conn) do
    user = Devloom.AccountsFixtures.user_fixture(%{name: "Alex"})
    scope = Devloom.Accounts.Scope.for_user(user)
    {:ok, workspace} = Devloom.Workspaces.create_workspace(scope, %{name: "Test workspace"})
    {:ok, scope} = Devloom.Workspaces.fetch_scope(scope, workspace.id)

    %{
      conn: conn |> log_in_user(user) |> Plug.Conn.assign(:test_scope, scope),
      user: user,
      scope: scope,
      workspace: workspace,
      board: Devloom.Boards.get_workspace_board!(scope)
    }
  end

  def second_conn(conn),
    do: log_in_user(Phoenix.ConnTest.build_conn(), conn.assigns.test_scope.user)

  def board_path(conn), do: "/workspaces/#{conn.assigns.test_scope.workspace.id}/board"
  def chat_path(conn), do: "/workspaces/#{conn.assigns.test_scope.workspace.id}/chat"
end
