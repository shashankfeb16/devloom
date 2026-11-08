defmodule DevloomWeb.SessionController do
  use DevloomWeb, :controller

  alias Devloom.Accounts
  alias DevloomWeb.UserAuth

  def new(conn, params) do
    if conn.assigns[:current_scope] && !UserAuth.safe_return_to(params["return_to"]) do
      redirect(conn, to: ~p"/workspaces")
    else
      {conn, return_to} = UserAuth.remember_return_to(conn, params)
      render_form(conn, %{"email" => ""}, return_to, nil)
    end
  end

  def create(conn, %{"user" => attrs} = params) do
    {conn, return_to} = UserAuth.remember_return_to(conn, params)

    if user = Accounts.get_user_by_email_and_password(attrs["email"], attrs["password"]) do
      UserAuth.log_in_user(conn, user, %{"return_to" => return_to})
    else
      conn
      |> put_status(:unprocessable_entity)
      |> render_form(
        %{"email" => safe_email(attrs["email"])},
        return_to,
        "The email or password is incorrect. Please try again."
      )
    end
  end

  def delete(conn, _params), do: UserAuth.log_out_user(conn)

  defp render_form(conn, attrs, return_to, error) do
    conn
    |> put_view(html: DevloomWeb.AuthHTML)
    |> render(:login,
      form: Phoenix.Component.to_form(attrs, as: :user),
      return_to: return_to,
      error: error,
      page_title: "Sign in"
    )
  end

  defp safe_email(email) when is_binary(email), do: String.slice(email, 0, 160)
  defp safe_email(_), do: ""
end
