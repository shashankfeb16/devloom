defmodule DevloomWeb.RegistrationController do
  use DevloomWeb, :controller

  alias Devloom.Accounts
  alias Devloom.Accounts.User
  alias DevloomWeb.UserAuth

  def new(conn, params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/workspaces")
    else
      {conn, return_to} = UserAuth.remember_return_to(conn, params)
      render_form(conn, Accounts.change_user_registration(%User{}), return_to)
    end
  end

  def create(%{assigns: %{current_scope: %Devloom.Accounts.Scope{}}} = conn, _params) do
    redirect(conn, to: ~p"/workspaces")
  end

  def create(conn, %{"user" => attrs} = params) do
    {conn, return_to} = UserAuth.remember_return_to(conn, params)

    case Devloom.Workspaces.register_user_with_legacy_workspace(attrs) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome to Devloom. Choose or create a workspace to get started.")
        |> UserAuth.log_in_user(user, %{"return_to" => return_to})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_form(changeset, return_to)
    end
  end

  defp render_form(conn, changeset, return_to) do
    conn
    |> put_view(html: DevloomWeb.AuthHTML)
    |> render(:register,
      form: Phoenix.Component.to_form(changeset, as: :user),
      return_to: return_to,
      page_title: "Create your account"
    )
  end
end
