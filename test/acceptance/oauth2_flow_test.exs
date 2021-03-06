defmodule Mithril.Acceptance.Oauth2FlowTest do
  use Mithril.Web.ConnCase
  alias Mithril.OTP

  @direct Mithril.ClientAPI.access_type(:direct)

  test "client successfully obtain an access_token API calls", %{conn: conn} do
    client_type = Mithril.Fixtures.create_client_type(%{scope: "legal_entity:read legal_entity:write"})
    client = Mithril.Fixtures.create_client(%{
      redirect_uri: "http://localhost",
      client_type_id: client_type.id,
      priv_settings: %{"access_type" => @direct}
    })
    user = Mithril.Fixtures.create_user(%{password: "super$ecre7"})
    user_role = Mithril.Fixtures.create_role(%{scope: "legal_entity:read legal_entity:write"})
    Mithril.UserRoleAPI.create_user_role(%{user_id: user.id, role_id: user_role.id, client_id: client.id})

    # 1. User is presented a user-agent and logs in
    login_request_body = %{
      "token" => %{
        "grant_type": "password",
        "email": user.email,
        "password": "super$ecre7",
        "client_id": client.id,
        "scope": "app:authorize"
      }
    }

    conn
    |> put_req_header("accept", "application/json")
    |> post("/oauth/tokens", Poison.encode!(login_request_body))

    # 2. After login user is presented with a list of scopes
    # The request goes through gateway, which
    # converts login_response["data"]["value"] into user_id
    # and puts it in as "x-consumer-id" header
    approval_request_body = %{
      "app" => %{
        "client_id": client.id,
        "redirect_uri": client.redirect_uri,
        "scope": "legal_entity:read legal_entity:write"
      }
    }

    approval_response =
      conn
      |> put_req_header("x-consumer-id", user.id)
      |> post("/oauth/apps/authorize", Poison.encode!(approval_request_body))

    code_grant =
      approval_response
      |> Map.get(:resp_body)
      |> Poison.decode!()
      |> get_in(["data", "value"])

    redirect_uri = "http://localhost?code=#{code_grant}"

    assert [^redirect_uri] = get_resp_header(approval_response, "location")

    # 3. After authorization server responds and
    # user-agent is redirected to client server,
    # client issues an access_token request
    tokens_request_body = %{
      "token" => %{
        "grant_type": "authorization_code",
        "client_id": client.id,
        "client_secret": client.secret,
        "code": code_grant,
        "scope": "legal_entity:read legal_entity:write",
        "redirect_uri": client.redirect_uri
      }
    }

    tokens_response =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/oauth/tokens", Poison.encode!(tokens_request_body))
      |> Map.get(:resp_body)
      |> Poison.decode!

    assert tokens_response["data"]["name"] == "access_token"
    assert tokens_response["data"]["value"]
    assert tokens_response["data"]["details"]["refresh_token"]
  end

  describe "2fa flow" do
    defmodule Microservices do
      use MicroservicesHelper

      Plug.Router.post "/sms/send" do
        Plug.Conn.send_resp(conn, 200, Poison.encode!(%{"data" => "sms sent"}))
      end
    end

    setup %{conn: conn} do
      user = insert(:user, password: Comeonin.Bcrypt.hashpwsalt("super$ecre7"))
      client_type = insert(:client_type, scope: "app:authorize legal_entity:read legal_entity:write")
      client = insert(
        :client,
        user_id: user.id,
        redirect_uri: "http://localhost",
        client_type_id: client_type.id,
        settings: %{"allowed_grant_types" => ["password"]},
        priv_settings: %{"access_type" => @direct}
      )
      insert(:authentication_factor, user_id: user.id)
      role = insert(:role, scope: "legal_entity:read legal_entity:write")
      insert(:user_role, user_id: user.id, role_id: role.id, client_id: client.id)

      {:ok, port, ref} = start_microservices(Microservices)
      System.put_env("OTP_ENDPOINT", "http://localhost:#{port}")
      on_exit fn ->
        System.delete_env("OTP_ENDPOINT")
        stop_microservices(ref)
      end

      %{conn: conn, user: user, client: client}
    end

    test "happy path", %{conn: conn, user: user, client: client} do
      login_request_body = %{
        "token" => %{
          "grant_type": "password",
          "email": user.email,
          "password": "super$ecre7",
          "client_id": client.id,
          "scope": "app:authorize"
        }
      }
      # 1. Create 2FA access token, that requires OTP confirmation
      resp =
        conn
        |> post("/oauth/tokens", Poison.encode!(login_request_body))
        |> json_response(201)
      assert "REQUEST_OTP" == resp["urgent"]["next_step"]
      assert "2fa_access_token" == resp["data"]["name"]
      otp_token_value = resp["data"]["value"]

      # OTP code will sent by third party. Let's get it from DB
      otp =
        OTP.list_otps
        |> List.first
        |> Map.get(:code)

      # 2. Verify OTP code and change 2FA access token to access token
      # The request goes direct to Mithril, bypassing Gateway,
      # so it requires authorization header with 2FA access token
      otp_request_body = %{
        "token" => %{
          "grant_type" => "authorize_2fa_access_token",
          "otp" => otp
        }
      }
      resp =
        conn
        |> put_req_header("authorization", "Bearer #{otp_token_value}")
        |> post("/oauth/tokens", Poison.encode!(otp_request_body))
        |> json_response(201)

      assert "REQUEST_APPS" == resp["urgent"]["next_step"]
      assert "access_token" == resp["data"]["name"]
      assert resp["data"]["value"]

      # 3. Create approval.
      # The request goes through Gateway, which
      # converts login_response["data"]["value"] into user_id
      # and puts it in as "x-consumer-id" header
      approval_request_body = %{
        "app" => %{
          "client_id": client.id,
          "redirect_uri": client.redirect_uri,
          "scope": "legal_entity:read legal_entity:write"
        }
      }

      approval_response =
        conn
        |> put_req_header("x-consumer-id", user.id)
        |> post("/oauth/apps/authorize", Poison.encode!(approval_request_body))

      code_grant =
        approval_response
        |> Map.get(:resp_body)
        |> Poison.decode!()
        |> get_in(["data", "value"])

      redirect_uri = "http://localhost?code=#{code_grant}"

      assert [^redirect_uri] = get_resp_header(approval_response, "location")

      # 4. After authorization server responds and
      # user-agent is redirected to client server,
      # client issues an access_token request
      tokens_request_body = %{
        "token" => %{
          "grant_type": "authorization_code",
          "client_id": client.id,
          "client_secret": client.secret,
          "code": code_grant,
          "scope": "legal_entity:read legal_entity:write",
          "redirect_uri": client.redirect_uri
        }
      }

      tokens_response =
        conn
        |> put_req_header("accept", "application/json")
        |> post("/oauth/tokens", Poison.encode!(tokens_request_body))
        |> Map.get(:resp_body)
        |> Poison.decode!

      assert tokens_response["data"]["name"] == "access_token"
      assert tokens_response["data"]["value"]
      assert tokens_response["data"]["details"]["refresh_token"]
    end

    test "2fa access token not send", %{conn: conn} do
      otp_request_body = %{
        "token" => %{
          "grant_type" => "authorize_2fa_access_token",
          "otp" => 123
        }
      }
      conn
      |> post("/oauth/tokens", Poison.encode!(otp_request_body))
      |> json_response(401)
    end

    test "invalid OTP", %{conn: conn, user: user, client: client} do
      login_request_body = %{
        "token" => %{
          "grant_type": "password",
          "email": user.email,
          "password": "super$ecre7",
          "client_id": client.id,
          "scope": "app:authorize"
        }
      }
      # 1. Create 2FA access token, that requires OTP confirmation
      otp_token_value =
        conn
        |> post("/oauth/tokens", Poison.encode!(login_request_body))
        |> json_response(201)
        |> get_in(~w(data value))

      # 2. Verify OTP code and change 2FA access token to access token
      # The request goes direct to Mithril, bypassing Gateway,
      # so it requires authorization header with 2FA access token
      otp_request_body = %{
        "token" => %{
          "grant_type" => "authorize_2fa_access_token",
          "otp" => 0
        }
      }
      assert "Invalid OTP code" ==
        conn
        |> put_req_header("authorization", "Bearer #{otp_token_value}")
        |> post("/oauth/tokens", Poison.encode!(otp_request_body))
        |> json_response(401)
        |> get_in(~w(error message))
    end
  end
end
