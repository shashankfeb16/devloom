defmodule Devloom.Accounts.Scope do
  @moduledoc "The account and workspace authorized for a request or LiveView."
  alias Devloom.Accounts.User

  defstruct [:user, :workspace, :membership]

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
