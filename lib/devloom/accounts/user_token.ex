defmodule Devloom.Accounts.UserToken do
  @moduledoc "Hashed, individually revocable account session tokens."
  use Ecto.Schema
  import Ecto.Query

  @validity_days 30

  schema "users_tokens" do
    field :token, :binary, redact: true
    field :context, :string
    belongs_to :user, Devloom.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def build_session_token(user) do
    raw = :crypto.strong_rand_bytes(32)
    {raw, %__MODULE__{user_id: user.id, token: hash(raw), context: "session"}}
  end

  def session_query(raw) when is_binary(raw) and byte_size(raw) == 32 do
    from token in __MODULE__,
      join: user in assoc(token, :user),
      where: token.context == "session" and token.token == ^hash(raw),
      where: token.inserted_at > ago(@validity_days, "day"),
      select: user
  end

  def session_query(_), do: nil

  def token_query(raw) when is_binary(raw) and byte_size(raw) == 32 do
    from token in __MODULE__, where: token.context == "session" and token.token == ^hash(raw)
  end

  def token_query(_), do: nil

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
