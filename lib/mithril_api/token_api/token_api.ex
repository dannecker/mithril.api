defmodule Mithril.TokenAPI do
  @moduledoc false

  use Mithril.Search
  import Ecto.{Query, Changeset}, warn: false

  alias Mithril.Repo
  alias Mithril.ClientAPI
  alias Mithril.TokenAPI.Token
  alias Mithril.ClientAPI.Client
  alias Mithril.TokenAPI.TokenSearch
  alias Mithril.Authentication
  alias Mithril.Authentication.Factor
  alias Mithril.Authorization.GrantType.AccessToken2FA

  @direct ClientAPI.access_type(:direct)
  @broker ClientAPI.access_type(:broker)

  @refresh_token "refresh_token"
  @access_token "access_token"
  @access_token_2fa "2fa_access_token"
  @authorization_code "authorization_code"

  @type_field "request_authentication_factor_type"
  @factor_field "request_authentication_factor"

  def list_tokens(params) do
    %TokenSearch{}
    |> token_changeset(params)
    |> search(params, Token)
  end

  def get_search_query(entity, %{client_id: client_id} = changes) do
    params =
      changes
      |> Map.delete(:client_id)
      |> Map.to_list()

    details_params = %{client_id: client_id}
    from e in entity,
         where: ^params,
         where: fragment("? @> ?", e.details, ^details_params)
  end
  def get_search_query(entity, changes), do: super(entity, changes)

  def get_token!(id), do: Repo.get!(Token, id)

  def get_token_by_value!(value), do: Repo.get_by!(Token, value: value)
  def get_token_by(attrs), do: Repo.get_by(Token, attrs)

  def create_token(attrs \\ %{}) do
    %Token{}
    |> token_changeset(attrs)
    |> Repo.insert()
  end

  # TODO: create refresh and auth token in transaction
  def create_refresh_token(attrs \\ %{}) do
    %Token{}
    |> refresh_token_changeset(attrs)
    |> Repo.insert()
  end

  def create_authorization_code(attrs \\ %{}) do
    %Token{}
    |> authorization_code_changeset(attrs)
    |> Repo.insert()
  end

  def create_access_token(attrs \\ %{}) do
    %Token{}
    |> access_token_changeset(attrs)
    |> Repo.insert()
  end

  def create_2fa_access_token(attrs \\ %{}) do
    %Token{}
    |> access_token_2fa_changeset(attrs)
    |> Repo.insert()
  end

  def init_factor(attrs) do
    with :ok <- AccessToken2FA.validate_authorization_header(attrs),
         {:ok, token} <- validate_token(attrs["token_value"]),
         %Ecto.Changeset{valid?: true} <- factor_changeset(attrs),
         where_factor <- prepare_factor_where_clause(token, attrs),
         %Factor{} = factor <- Authentication.get_factor_by!(where_factor),
         :ok <- validate_token_type(token, factor),
         token_data <- prepare_token_data(token, attrs),
         {:ok, token_2fa} <- create_2fa_access_token(token_data),
         Authentication.send_otp(%Factor{factor: attrs["factor"], type: Authentication.type(:sms)}, token_2fa)
      do
      {:ok, token_2fa}
    end
  end

  def approve_factor(attrs) do
    with :ok <- AccessToken2FA.validate_authorization_header(attrs),
         {:ok, token} <- validate_token(attrs["token_value"]),
         :ok <- validate_approve_token(token),
         where_factor <- prepare_factor_where_clause(token),
         %Factor{} = factor <- Authentication.get_factor_by!(where_factor),
         :ok <- AccessToken2FA.verify_otp(token.details[@factor_field], token, attrs["otp"]),
         {:ok, updated_factor} <- Authentication.update_factor(factor, %{"factor" => token.details[@factor_field]})
      do
      {:ok, updated_factor.user}
    end
  end

  defp validate_token(token_value) do
    with %Token{} = token <- get_token_by([value: token_value]),
         false <- expired?(token)
      do
      {:ok, token}
    else
      true -> {:error, {:access_denied, "Token expired"}}
      nil -> {:error, {:access_denied, "Invalid token"}}
    end
  end

  defp validate_approve_token(%Token{details: %{@factor_field => _, @type_field => _}}), do: :ok
  defp validate_approve_token(_), do: {:error, {:access_denied, "Invalid token type. Init factor at first"}}

  defp validate_token_type(%Token{name: @access_token_2fa}, %Factor{factor: val}) when (is_nil(val) or "" == val) do
    :ok
  end
  defp validate_token_type(%Token{name: @access_token}, %Factor{factor: val}) when byte_size(val) > 0 do
    :ok
  end
  defp validate_token_type(_, _) do
    {:error, {:access_denied, "Invalid token type"}}
  end

  defp prepare_factor_where_clause(%Token{user_id: user_id, details: %{@type_field => type}}) do
    [user_id: user_id, is_active: true, type: type]
  end

  defp prepare_factor_where_clause(%Token{} = token, %{"type" => type}) do
    [user_id: token.user_id, is_active: true, type: type]
  end

  defp prepare_token_data(%Token{} = token, attrs) do
    %{user_id: token.user_id, details: token.details}
    %{
      user_id: token.user_id,
      details: Map.merge(token.details, %{
        request_authentication_factor: attrs["factor"],
        request_authentication_factor_type: attrs["type"],
      })
    }
  end

  def update_token(%Token{} = token, attrs) do
    token
    |> token_changeset(attrs)
    |> Repo.update()
  end

  def delete_token(%Token{} = token) do
    Repo.delete(token)
  end

  def delete_tokens_by_user_ids(user_ids) do
    q = from(t in Token, where: t.user_id in ^user_ids)
    Repo.delete_all(q)
  end

  def delete_tokens_by_params(params) do
    %TokenSearch{}
    |> token_changeset(params)
    |> case do
         %Ecto.Changeset{valid?: true, changes: changes} ->
           Token |> get_search_query(changes) |> Repo.delete_all()

         changeset
         -> changeset
       end
  end

  def change_token(%Token{} = token) do
    token_changeset(token, %{})
  end

  def verify(token_value) do
    token = get_token_by_value!(token_value)

    with false <- expired?(token),
         _app <- Mithril.AppAPI.approval(token.user_id, token.details["client_id"]) do
      # if token is authorization_code or password - make sure was not used previously
      {:ok, token}
    else
      _ ->
        message = "Token expired or client approval was revoked."
        Mithril.Authorization.GrantType.Error.invalid_grant(message)
    end
  end

  def verify_client_token(token_value, api_key) do
    token = get_token_by_value!(token_value)

    with false <- expired?(token),
         _app <- Mithril.AppAPI.approval(token.user_id, token.details["client_id"]),
         client <- ClientAPI.get_client!(token.details["client_id"]),
         :ok <- check_client_is_blocked(client),
         {:ok, token} <- put_broker_scopes(token, client, api_key) do
      {:ok, token}
    else
      {:error, _, _} = err ->
        err
      _ ->
        message = "Token expired or client approval was revoked."
        Mithril.Authorization.GrantType.Error.invalid_grant(message)
    end
  end

  def expired?(%Token{} = token) do
    token.expires_at < :os.system_time(:seconds)
  end

  defp put_broker_scopes(token, client, api_key) do
    case Map.get(client.priv_settings, "access_type") do
      nil -> {:error, %{invalid_client: "Client settings must contain access_type."}, :unprocessable_entity}

      # Clients such as NHS Admin, MIS
      @direct -> {:ok, token}

      # Clients such as MSP, PHARMACY
      @broker ->
        api_key
        |> validate_api_key()
        |> fetch_client_by_secret()
        |> fetch_broker_scope()
        |> put_broker_scope_into_token_details(token)
    end
  end

  defp validate_api_key(api_key) when is_binary(api_key), do: api_key
  defp validate_api_key(_), do: {:error, %{api_key: "API-KEY header required."}, :unprocessable_entity}

  defp fetch_client_by_secret({:error, errors, status}), do: {:error, errors, status}
  defp fetch_client_by_secret(api_key) do
    case ClientAPI.get_client_by([secret: api_key]) do
      %ClientAPI.Client{} = client -> client
      _ ->
        {:error, %{api_key: "API-KEY header is invalid."}, :unprocessable_entity}
    end
  end

  defp fetch_broker_scope({:error, errors, status}), do: {:error, errors, status}
  defp fetch_broker_scope(%ClientAPI.Client{priv_settings: %{"broker_scope" => broker_scope}}) do
    broker_scope
  end
  defp fetch_broker_scope(_) do
    {:error, %{broker_settings: "Incorrect broker settings."}, :unprocessable_entity}
  end

  defp put_broker_scope_into_token_details({:error, errors, status}, _token), do: {:error, errors, status}
  defp put_broker_scope_into_token_details(broker_scope, token) do
    details = Map.put(token.details, "broker_scope", broker_scope)
    {:ok, Map.put(token, :details, details)}
  end

  def deactivate_old_tokens(%Token{id: id, user_id: user_id, name: name}) do
    now = :os.system_time(:seconds)
    Token
    |> where([t], t.id != ^id)
    |> where([t], t.name == ^name and t.user_id == ^user_id)
    |> where([t], t.expires_at >= ^now)
    |> where([t], fragment("?->>'grant_type' = 'password'", t.details))
    |> Repo.update_all(set: [expires_at: now])
  end

  @uuid_regex ~r|[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}|

  defp factor_changeset(attrs) do
    types = %{type: :string, factor: :string}

    {%{}, types}
    |> cast(attrs, Map.keys(types))
    |> validate_required(Map.keys(types))
    |> validate_inclusion(:type, [Authentication.type(:sms)])
    |> Authentication.validate_factor_format()
  end

  defp token_changeset(%Token{} = token, attrs) do
    token
    |> cast(attrs, [:name, :user_id, :value, :expires_at, :details])
    |> validate_format(:user_id, @uuid_regex)
    |> validate_required([:name, :user_id, :value, :expires_at, :details])
  end

  defp token_changeset(%TokenSearch{} = token, attrs) do
    token
    |> cast(attrs, [:name, :value, :user_id, :client_id])
    |> validate_format(:user_id, @uuid_regex)
    |> set_like_attributes([:name, :value])
  end

  defp token_changeset(%Token{} = token, attrs, type, name) do
    token
    |> cast(attrs, [:name, :expires_at, :details, :user_id])
    |> validate_required([:user_id])
    |> put_change(:value, SecureRandom.urlsafe_base64)
    |> put_change(:name, name)
    |> put_change(:expires_at, :os.system_time(:seconds) + Map.fetch!(get_token_lifetime(), type))
    |> unique_constraint(:value, name: :tokens_value_name_index)
  end

  defp refresh_token_changeset(%Token{} = token, attrs) do
    token_changeset(token, attrs, :refresh, @refresh_token)
  end

  defp access_token_changeset(%Token{} = token, attrs) do
    token_changeset(token, attrs, :access, @access_token)
  end

  defp access_token_2fa_changeset(%Token{} = token, attrs) do
    token_changeset(token, attrs, :access, @access_token_2fa)
  end

  defp authorization_code_changeset(%Token{} = token, attrs) do
    token_changeset(token, attrs, :code, @authorization_code)
  end

  defp get_token_lifetime,
       do: Confex.fetch_env!(:mithril_api, :token_lifetime)

  defp check_client_is_blocked(%Client{is_blocked: false}), do: :ok
  defp check_client_is_blocked(_) do
    {:error, %{invalid_client: "Authentication failed"}, :unauthorized}
  end
end
