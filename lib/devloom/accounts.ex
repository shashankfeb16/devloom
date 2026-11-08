defmodule Devloom.Accounts do
  @moduledoc "Account registration, password authentication, and revocable sessions."
  alias Devloom.Accounts.{User, UserToken}
  alias Devloom.Repo

  def register_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  def get_user_by_email_and_password(email, password) when is_binary(email) do
    user = Repo.get_by(User, email: User.normalize_email(email))
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_email_and_password(_, password) do
    User.valid_password?(nil, password)
    nil
  end

  def generate_user_session_token(%User{} = user) do
    {raw, token} = UserToken.build_session_token(user)
    Repo.insert!(token)
    raw
  end

  def get_user_by_session_token(raw) do
    case UserToken.session_query(raw) do
      nil -> nil
      query -> Repo.one(query)
    end
  end

  def delete_user_session_token(raw) do
    case UserToken.token_query(raw) do
      nil -> :ok
      query -> Repo.delete_all(query)
    end

    :ok
  end
end
