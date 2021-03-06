defmodule Mithril.Authorization.GrantType.AccessToken2FA do
  @moduledoc false
  import Ecto.Changeset

  alias Mithril.UserAPI
  alias Mithril.UserAPI.User
  alias Mithril.TokenAPI
  alias Mithril.TokenAPI.Token
  alias Mithril.Authentication
  alias Mithril.Authentication.Factor
  alias Mithril.Authorization.GrantType.Password

  @otp_error_max Confex.get_env(:mithril_api, :user_otp_error_max)

  def authorize(params) do
    with %Ecto.Changeset{valid?: true} <- changeset(params),
         :ok <- validate_authorization_header(params),
         {:ok, token_2fa} <- validate_token(params["token_value"]),
         user <- UserAPI.get_user(token_2fa.user_id),
         {:ok, user} <- validate_user(user),
         %Factor{} = factor <- get_auth_factor_by_user_id(user.id),
         :ok <- verify_otp(factor, token_2fa, params["otp"]),
         {:ok, token} <- create_access_token(token_2fa),
         {_, nil} <- Mithril.TokenAPI.deactivate_old_tokens(token)
      do
      {:ok, %{token: token, urgent: %{next_step: Password.next_step(:request_apps)}}}
    end
  end

  def refresh(params) do
    with :ok <- validate_authorization_header(params),
         {:ok, token_2fa} <- validate_token(params["token_value"]),
         user <- UserAPI.get_user(token_2fa.user_id),
         {:ok, user} <- validate_user(user),
         %Factor{} <- get_auth_factor_by_user_id(user.id),
         {:ok, token} <- create_2fa_access_token(token_2fa),
         {_, nil} <- Mithril.TokenAPI.deactivate_old_tokens(token)
      do
      {:ok, %{token: token, urgent: %{next_step: Password.next_step(:request_otp)}}}
    end
  end

  defp changeset(attrs) do
    types = %{otp: :integer}

    {%{}, types}
    |> cast(attrs, Map.keys(types))
    |> validate_required(Map.keys(types))
  end

  def validate_authorization_header(%{"token_value" => token_value}) when is_binary(token_value) do
    :ok
  end
  def validate_authorization_header(_) do
    {:error, {:access_denied, "Authorization header required."}}
  end

  defp validate_token(token_value) do
    with %Token{name: "2fa_access_token"} = token <- TokenAPI.get_token_by([value: token_value]),
         false <- TokenAPI.expired?(token)
      do
      {:ok, token}
    else
      %Token{} -> {:error, {:access_denied, "Invalid token type"}}
      true -> {:error, {:access_denied, "Token expired"}}
      nil -> {:error, {:access_denied, "Invalid token"}}
    end
  end

  def validate_user(%User{is_blocked: false} = user), do: {:ok, user}
  def validate_user(%User{is_blocked: true}), do: {:error, {:access_denied, "User blocked."}}
  def validate_user(_), do: {:error, {:access_denied, "User not found."}}

  defp get_auth_factor_by_user_id(user_id) do
    case Authentication.get_factor_by([user_id: user_id, is_active: true]) do
      %Factor{} = factor -> factor
      _ -> {:error, %{conflict: "Not found authentication factor for user."}}

    end
  end

  def verify_otp(factor, token, otp) do
    case Authentication.verify_otp(factor, token, otp) do
      {_, _, :verified} -> :ok
      _ -> {:error, {:access_denied, "Invalid OTP code"}}
    end
  end

  defp create_access_token(%Token{} = token) do
    Mithril.TokenAPI.create_access_token(%{
      user_id: token.user_id,
      details: token.details
    })
  end

  defp create_2fa_access_token(%Token{} = token) do
    Mithril.TokenAPI.create_2fa_access_token(%{
      user_id: token.user_id,
      details: token.details
    })
  end

  defp check_otp_error_counter({:error, _, _} = err, %User{priv_settings: priv_settings} = user) do
    otp_error = priv_settings.otp_error_counter + 1
    case @otp_error_max <= otp_error do
      true ->
        UserAPI.block_user(user, "Passed invalid password more than USER_OTP_ERROR_MAX")
      _ ->
        data = priv_settings
               |> Map.from_struct()
               |> Map.put(:otp_error_counter, otp_error)
        UserAPI.update_user_priv_settings(user, data)
    end
    err
  end
  defp check_otp_error_counter({:ok, user}, _) do
    {:ok, user}
  end
end
