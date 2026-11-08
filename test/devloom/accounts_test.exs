defmodule Devloom.AccountsTest do
  use Devloom.DataCase, async: true

  import Devloom.AccountsFixtures
  alias Devloom.Accounts
  alias Devloom.Accounts.{Scope, User, UserToken}

  test "registration normalizes account fields and stores only a password hash" do
    attrs = valid_user_attributes(%{name: "  Sam  ", email: " SAM@Example.COM "})
    assert {:ok, user} = Accounts.register_user(attrs)
    assert user.name == "Sam"
    assert user.email == "sam@example.com"
    assert user.password == nil
    assert user.password_confirmation == nil
    assert Bcrypt.verify_pass(attrs.password, user.hashed_password)
    refute inspect(user) =~ user.hashed_password
    refute inspect(user) =~ attrs.password
    assert Repo.get!(User, user.id).hashed_password == user.hashed_password
  end

  test "registration validates names, email, password length, and confirmation" do
    for {attrs, field} <- [
          {%{name: " "}, :name},
          {%{name: String.duplicate("界", 51)}, :name},
          {%{email: "not-an-email"}, :email},
          {%{password: "too short", password_confirmation: "too short"}, :password},
          {%{
             password: String.duplicate("界", 25),
             password_confirmation: String.duplicate("界", 25)
           }, :password},
          {%{password_confirmation: "different password"}, :password_confirmation},
          {%{password_confirmation: nil}, :password_confirmation}
        ] do
      assert {:error, changeset} = Accounts.register_user(valid_user_attributes(attrs))
      assert Map.has_key?(errors_on(changeset), field)
      assert get_change(changeset, :hashed_password) == nil
    end
  end

  test "normalized emails are unique and managed fields cannot be supplied" do
    existing = user_fixture(%{email: "sam@example.com"})

    assert {:error, changeset} =
             Accounts.register_user(valid_user_attributes(%{email: " SAM@EXAMPLE.COM "}))

    assert "has already been taken" in errors_on(changeset).email

    assert {:ok, user} =
             Accounts.register_user(
               valid_user_attributes(%{id: existing.id, hashed_password: "attacker-controlled"})
             )

    assert user.id != existing.id
    assert user.hashed_password != "attacker-controlled"
  end

  test "authentication accepts a normalized email and rejects invalid credentials" do
    user = user_fixture(%{email: "sam@example.com"})

    assert Accounts.get_user_by_email_and_password(" SAM@EXAMPLE.COM ", valid_user_password()).id ==
             user.id

    for {email, password} <- [
          {user.email, "wrong password"},
          {"missing@example.com", valid_user_password()},
          {nil, valid_user_password()},
          {user.email, nil},
          {user.email, String.duplicate("x", 100)}
        ] do
      assert Accounts.get_user_by_email_and_password(email, password) == nil
    end
  end

  test "session tokens are hashed, independently revocable, and expire" do
    user = user_fixture()
    first = Accounts.generate_user_session_token(user)
    second = Accounts.generate_user_session_token(user)
    assert byte_size(first) == 32
    refute first == second
    [stored_first, stored_second] = Repo.all(from token in UserToken, order_by: token.id)
    assert stored_first.token == :crypto.hash(:sha256, first)
    assert stored_first.token != first
    assert Accounts.get_user_by_session_token(first).id == user.id

    assert :ok = Accounts.delete_user_session_token(first)
    assert Accounts.get_user_by_session_token(first) == nil
    assert Accounts.get_user_by_session_token(second).id == user.id

    expiry = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

    Repo.update_all(from(token in UserToken, where: token.id == ^stored_second.id),
      set: [inserted_at: expiry]
    )

    assert Accounts.get_user_by_session_token(second) == nil

    for invalid <- [nil, "not-a-token", %{}, 123] do
      assert Accounts.get_user_by_session_token(invalid) == nil
      assert Accounts.delete_user_session_token(invalid) == :ok
    end
  end

  test "scope contains only the authenticated account until a workspace is authorized" do
    user = user_fixture()
    assert %Scope{user: ^user, workspace: nil, membership: nil} = Scope.for_user(user)
    assert Scope.for_user(nil) == nil
  end
end
