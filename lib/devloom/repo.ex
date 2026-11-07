defmodule Devloom.Repo do
  use Ecto.Repo,
    otp_app: :devloom,
    adapter: Ecto.Adapters.Postgres
end
