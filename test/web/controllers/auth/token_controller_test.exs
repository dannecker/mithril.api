defmodule Mithril.OAuth.TokenControllerTest do
  use Mithril.Web.ConnCase

  alias Mithril.TokenAPI.Token

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  test "user is blocked", %{conn: conn} do
    password = "somepa$$word"
    user = insert(:user, password: Comeonin.Bcrypt.hashpwsalt(password), is_blocked: true)
    client_type = insert(:client_type, scope: "app:authorize")
    client = insert(:client,
      user_id: user.id,
      client_type_id: client_type.id,
      settings: %{"allowed_grant_types" => ["password"]}
    )

    request_payload = %{
      "token": %{
        "grant_type": "password",
        "email": user.email,
        "password": password,
        "client_id": client.id,
        "scope": "app:authorize"
      }
    }
    conn = post(conn, "/oauth/tokens", Poison.encode!(request_payload))
    assert "User blocked." == json_response(conn, 401)["error"]["message"]
  end

  test "successfully issues new access_token using password. Next step: send OTP", %{conn: conn} do
    allowed_scope = "app:authorize legal_entity:read legal_entity:write"
    password = "secret_password"
    user = insert(:user, password: Comeonin.Bcrypt.hashpwsalt(password))
    client_type = insert(:client_type, scope: allowed_scope)
    client = insert(:client,
      user_id: user.id,
      client_type_id: client_type.id,
      settings: %{"allowed_grant_types" => ["password"]}
    )
    insert(:authentication_factor, user_id: user.id)

    request_payload = %{
      "token": %{
        "grant_type": "password",
        "email": user.email,
        "password": password,
        "client_id": client.id,
        "scope": "app:authorize"
      }
    }

    conn = post(conn, "/oauth/tokens", Poison.encode!(request_payload))

    resp = json_response(conn, 201)
    assert Map.has_key?(resp, "urgent")
    assert Map.has_key?(resp["urgent"], "next_step")
    assert "REQUEST_OTP" = resp["urgent"]["next_step"]

    token = resp["data"]
    assert token["name"] == "2fa_access_token"
    assert token["value"]
    assert token["expires_at"]
    assert token["user_id"] == user.id
    assert token["details"]["client_id"] == client.id
    assert token["details"]["grant_type"] == "password"
    assert token["details"]["redirect_uri"] == client.redirect_uri
    assert token["details"]["scope"] == "app:authorize"
  end

  test "successfully issues new access_token using code_grant", %{conn: conn} do
    client = Mithril.Fixtures.create_client()
    user   = Mithril.Fixtures.create_user(%{password: "secret_password"})

    Mithril.AppAPI.create_app(%{
      user_id: user.id,
      client_id: client.id,
      scope: "legal_entity:read legal_entity:write"
    })

    {:ok, code_grant} = Mithril.Fixtures.create_code_grant_token(client, user, "legal_entity:read")

    request_payload = %{
      "token": %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "client_secret" => client.secret,
        "redirect_uri" => client.redirect_uri,
        "code" => code_grant.value
      }
    }

    conn = post(conn, "/oauth/tokens", Poison.encode!(request_payload))

    token = json_response(conn, 201)["data"]

    assert token["name"] == "access_token"
    assert token["value"]
    assert token["expires_at"]
    assert token["user_id"] == user.id
    assert token["details"]["client_id"] == client.id
    assert token["details"]["grant_type"] == "authorization_code"
    assert token["details"]["redirect_uri"] == client.redirect_uri
    assert token["details"]["scope"] == "legal_entity:read"
  end

  test "incorrectly crafted body is still treated nicely", %{conn: conn} do
    assert_error_sent 400, fn ->
      post(conn, "/oauth/tokens", Poison.encode!(%{"scope" => "legal_entity:read"}))
    end
  end

  test "errors are rendered as json", %{conn: conn} do
    request = %{
      "token" => %{
        "scope" => "legal_entity:read"
      }
    }

    conn = post(conn, "/oauth/tokens", Poison.encode!(request))

    result = json_response(conn, 400)["error"]
    assert result["invalid_client"] == "Request must include grant_type."
  end

  test "expire old password tokens", %{conn: conn} do
    allowed_scope = "app:authorize"
    client_type = Mithril.Fixtures.create_client_type(%{scope: allowed_scope})
    client = Mithril.Fixtures.create_client(%{
      settings: %{"allowed_grant_types" => ["password"]},
      client_type_id: client_type.id
    })
    user = Mithril.Fixtures.create_user(%{password: "secret_password"})

    request_payload = %{
      "token": %{
        "grant_type": "password",
        "email": user.email,
        "password": "secret_password",
        "client_id": client.id,
        "scope": "app:authorize"
      }
    }

    conn1 = post(conn, "/oauth/tokens", Poison.encode!(request_payload))
    %{"data" => %{"id" => token1_id, "expires_at" => expires_at}} = json_response(conn1, 201)
    conn2 = post(conn, "/oauth/tokens", Poison.encode!(request_payload))
    assert json_response(conn2, 201)

    now = DateTime.to_unix(DateTime.utc_now)
    assert expires_at > now

    %{expires_at: expires_at} = Repo.get!(Token, token1_id)
    assert expires_at <= now
  end
end
