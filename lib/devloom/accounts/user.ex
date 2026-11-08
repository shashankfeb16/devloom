defmodule Devloom.Accounts.User do
  @moduledoc "An account identified by an email address and a password hash."
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:name, :email, :password, :password_confirmation])
    |> update_change(:name, &String.trim/1)
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:name, :email, :password])
    |> validate_length(:name, min: 1, max: 50, count: :codepoints)
    |> validate_length(:email, max: 160)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> unsafe_validate_unique(:email, Devloom.Repo)
    |> unique_constraint(:email, name: :users_email_index)
    |> validate_length(:password, min: 12)
    |> validate_length(:password, max: 72, count: :bytes)
    |> validate_confirmation(:password, required: true)
    |> maybe_hash_password(opts)
  end

  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password) and byte_size(password) > 0 and
             byte_size(password) <= 72 do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  defp maybe_hash_password(changeset, opts) do
    if Keyword.get(opts, :hash_password, true) && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(get_change(changeset, :password)))
      |> delete_change(:password)
      |> delete_change(:password_confirmation)
    else
      changeset
    end
  end
end
