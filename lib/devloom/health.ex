defmodule Devloom.Health do
  @moduledoc "Checks whether the workspace can reach its database."

  @spec check() :: :ok | :error
  def check do
    case Ecto.Adapters.SQL.query(Devloom.Repo, "SELECT 1", [],
           timeout: 2_000,
           pool_timeout: 2_000,
           log: false
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> :error
  catch
    :exit, _reason -> :error
  end
end
