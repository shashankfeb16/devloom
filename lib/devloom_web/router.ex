defmodule DevloomWeb.Router do
  use DevloomWeb, :router

  import DevloomWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DevloomWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DevloomWeb do
    pipe_through :browser

    get "/", HomeController, :index
    get "/chat", HomeController, :index
    get "/users/register", RegistrationController, :new
    post "/users/register", RegistrationController, :create
    get "/users/log_in", SessionController, :new
    post "/users/log_in", SessionController, :create
    delete "/users/log_out", SessionController, :delete

    live_session :invitation,
      on_mount: [{DevloomWeb.UserAuth, :mount_current_scope}] do
      live "/invitations/:token", InvitationLive
    end
  end

  scope "/", DevloomWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [{DevloomWeb.UserAuth, :ensure_authenticated}] do
      live "/workspaces", WorkspaceLive
    end

    live_session :workspace,
      on_mount: [
        {DevloomWeb.UserAuth, :ensure_authenticated},
        {DevloomWeb.WorkspaceAuth, :ensure_member}
      ] do
      live "/workspaces/:workspace_id/board", BoardLive
      live "/workspaces/:workspace_id/chat", ChatLive, :team
      live "/workspaces/:workspace_id/chat/direct/:member_id", ChatLive, :direct
      live "/workspaces/:workspace_id/members", WorkspaceMembersLive
    end
  end

  scope "/", DevloomWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", DevloomWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:devloom, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DevloomWeb.Telemetry
    end
  end
end
