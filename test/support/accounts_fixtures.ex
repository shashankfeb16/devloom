defmodule Devloom.AccountsFixtures do
  @moduledoc "Account fixtures shared by authentication and workspace tests."

  def unique_user_email, do: "user-#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "a long valid password"

  def valid_user_attributes(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    Map.merge(
      %{
        name: "Alex",
        email: unique_user_email(),
        password: valid_user_password(),
        password_confirmation: Map.get(attrs, :password, valid_user_password())
      },
      attrs
    )
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} = attrs |> valid_user_attributes() |> Devloom.Accounts.register_user()
    user
  end
end
