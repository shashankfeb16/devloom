defmodule DevloomWeb.AuthControllerTest do
  use DevloomWeb.ConnCase, async: false

  import Devloom.AccountsFixtures
  alias Devloom.Accounts

  test "signup and signin pages expose labeled forms", %{conn: conn} do
    registration =
      conn |> get(~p"/users/register") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(registration, "#registration-form[action='/users/register']")
           |> Enum.any?()

    assert LazyHTML.query(registration, "input[name='user[password_confirmation]']")
           |> Enum.any?()

    login =
      conn
      |> recycle()
      |> get(~p"/users/log_in")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.query(login, "#login-form[action='/users/log_in']") |> Enum.any?()
  end

  test "signup creates an account, renews the session, and signs in", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{discard_me: true})
      |> post(~p"/users/register", user: valid_user_attributes())

    assert redirected_to(conn) == ~p"/workspaces"
    refute get_session(conn, :discard_me)
    assert token = get_session(conn, :user_token)
    assert Accounts.get_user_by_session_token(token)
    assert get_session(conn, :live_socket_id)
  end

  test "a signed-in account cannot accidentally register another account", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    original_token = get_session(conn, :user_token)
    count = Devloom.Repo.aggregate(Devloom.Accounts.User, :count)

    response = post(conn, ~p"/users/register", user: valid_user_attributes())

    assert redirected_to(response) == ~p"/workspaces"
    assert Devloom.Repo.aggregate(Devloom.Accounts.User, :count) == count
    assert get_session(response, :user_token) == original_token
    assert Accounts.get_user_by_session_token(original_token).id == user.id
  end

  test "invalid signup keeps ordinary fields but never renders password values", %{conn: conn} do
    params =
      valid_user_attributes(%{
        password: "short-secret",
        password_confirmation: "different-secret"
      })

    conn = post(conn, ~p"/users/register", user: params)
    assert conn.status == 422
    document = conn |> html_response(422) |> LazyHTML.from_document()

    assert LazyHTML.query(
             document,
             "#registration-form input[name='user[email]'][value='#{params.email}']"
           )
           |> Enum.any?()

    assert LazyHTML.query(document, "input[type='password'][value='']") |> Enum.count() == 2
    refute get_session(conn, :user_token)
  end

  test "signin rejects wrong credentials with the same generic error", %{conn: conn} do
    user = user_fixture()

    for email <- [user.email, "unknown@example.com"] do
      response =
        conn
        |> recycle()
        |> post(~p"/users/log_in", user: %{email: email, password: "bad-secret"})

      assert html_response(response, 422) =~ "The email or password is incorrect."

      assert response
             |> html_response(422)
             |> LazyHTML.from_document()
             |> LazyHTML.query("input[type='password'][value='']")
             |> Enum.any?()

      refute get_session(response, :user_token)
    end
  end

  test "signin and logout rotate the session and revoke only its token", %{conn: conn} do
    user = user_fixture()
    independent = Accounts.generate_user_session_token(user)

    conn =
      conn
      |> init_test_session(%{discard_me: true})
      |> post(~p"/users/log_in", user: %{email: user.email, password: valid_user_password()})

    assert redirected_to(conn) == ~p"/workspaces"
    refute get_session(conn, :discard_me)
    token = get_session(conn, :user_token)
    assert Accounts.get_user_by_session_token(token).id == user.id

    conn = conn |> recycle() |> delete(~p"/users/log_out")
    assert redirected_to(conn) == ~p"/users/log_in"
    refute get_session(conn, :user_token)
    assert Accounts.get_user_by_session_token(token) == nil
    assert Accounts.get_user_by_session_token(independent).id == user.id
  end

  test "only invitation return paths survive authentication", %{conn: conn} do
    user = user_fixture()
    invite_path = "/invitations/" <> String.duplicate("a", 43)

    login =
      conn
      |> get(~p"/users/log_in?#{[return_to: invite_path]}")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.query(login, "input[name='return_to'][value='#{invite_path}']") |> Enum.any?()

    for path <- [
          "https://evil.example",
          "//evil.example",
          "/workspaces/999",
          "/invitations/token?next=evil"
        ] do
      response =
        conn
        |> recycle()
        |> post(~p"/users/log_in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()},
          "return_to" => path
        })

      assert redirected_to(response) == ~p"/workspaces"
    end

    response =
      conn
      |> recycle()
      |> post(~p"/users/log_in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()},
        "return_to" => invite_path
      })

    assert redirected_to(response) == invite_path
  end
end
