defmodule DevloomWeb.ObservabilityTestRouter do
  use Phoenix.Router, helpers: false

  get "/probe/:id", DevloomWeb.ObservabilityTestPlug, :show
end
