defmodule Mithril.OAuth.AppControllerTest do
  use Mithril.Web.ConnCase

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  test "successfully approves client request", %{conn: conn} do
    client = Mithril.Fixtures.create_client()
    user   = Mithril.Fixtures.create_user()

    {:ok, token} =
      Mithril.TokenAPI.create_token(%{
        details: %{
          scope: "app:authorize",
          client_id: client.id,
          grant_type: "password",
          redirect_uri: client.redirect_uri
        },
        user_id: user.id,
        expires_at: 2000000000, # 2050
        name: "access_token",
        value: "token_token_token"
      })

    request = %{
      app: %{
        client_id: client.id,
        redirect_uri: client.redirect_uri,
        scope: "some_api:read,some_api:write",
      }
    }

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token.value}")
      |> post("/oauth/apps/authorize", Poison.encode!(request))

    result = json_response(conn, 201)["data"]

    assert result["value"]
    assert result["user_id"]
    assert result["name"]
    assert result["expires_at"]
    assert result["details"]["scope"]
    assert result["details"]["redirect_uri"]
    assert result["details"]["client_id"]

    [header] = Plug.Conn.get_resp_header(conn, "location")

    assert "#{token.details.redirect_uri}?code=#{result["value"]}" == header
  end
end
