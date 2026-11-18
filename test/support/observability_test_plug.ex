defmodule DevloomWeb.ObservabilityTestPlug do
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_params: %{"id" => "boom"}}, :show), do: raise("test request failure")
  def call(conn, :show), do: send_resp(conn, 200, "ok")
end
