use Mix.Config

# Configuration for test environment
config :ex_unit, capture_log: true

# Configure your database
config :mithril_api, Mithril.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  database: {:system, "DB_NAME", "mithril_api_test"}

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mithril_api, Mithril.Web.Endpoint,
  http: [port: 4001],
  server: true

# Print only warnings and errors during test
config :logger, level: :debug

config :bcrypt_elixir, :log_rounds, 4

# Run acceptance test in concurrent mode
config :mithril_api,
  sql_sandbox: true

config :mithril_api, :"2fa",
  otp_ttl: 1,
  user_2fa_enabled?: {:system, :boolean, "USER_2FA_ENABLED", true},
  sms_enabled?: {:system, :boolean, "SMS_ENABLED", false}
