use Mix.Config

config :authable,
  ecto_repos: [Authable.Repo],
  repo: Authable.Repo,
  resource_owner: Authable.Model.User,
  token_store: Authable.Model.Token,
  client: Authable.Model.Client,
  app: Authable.Model.App,
  expires_in: %{
    access_token: 30 * 24 * 3600,
    refresh_token: 24 * 3600,
    authorization_code: 300,
    session_token: 30 * 24 * 3600
  },
  grant_types: %{
    authorization_code: Authable.GrantType.AuthorizationCode,
    client_credentials: Authable.GrantType.ClientCredentials,
    password: Authable.GrantType.Password,
    refresh_token: Authable.GrantType.RefreshToken
  },
  auth_strategies: %{
    headers: %{
      "authorization" => [
        {~r/Basic ([a-zA-Z\-_\+=]+)/, Authable.Authentication.Basic},
        {~r/Bearer ([a-zA-Z\-_\+=]+)/, Authable.Authentication.Bearer},
      ],
      "x-api-token" => [
        {~r/([a-zA-Z\-_\+=]+)/, Authable.Authentication.Bearer}
      ]
    },
    query_params: %{
      "access_token" => Authable.Authentication.Bearer
    },
    sessions: %{
      "session_token" => Authable.Authentication.Session
    }
  },
  scopes: ~w(app:authorize some_api:read some_api:write legal_entity:read legal_entity:write),
  renderer: Authable.Renderer.RestApi
