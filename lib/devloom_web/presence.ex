defmodule DevloomWeb.Presence do
  @moduledoc "Tracks live workspace connections without storing account details."
  use Phoenix.Presence,
    otp_app: :devloom,
    pubsub_server: Devloom.PubSub
end
