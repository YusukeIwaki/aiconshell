# frozen_string_literal: true

require "db_helper"
require "tempfile"
require "openssl"
require_relative "support/admin_test_support"
require_relative "support/task_request_test_support"
require_relative "../../plugins/support/fake_transport"

include PluginsTestSupport
AccountsHealthCheck = Accounts::HealthCheck

def accounts_transport
  clock = FakeClock.new(Time.utc(2026, 9, 26, 12, 0, 0))
  FakeTransport.new(clock: clock)
end

def accounts_pem
  TestKeys.github_private_key
end

def accounts_upload(content, filename = "app-key.pem")
  file = Tempfile.new([File.basename(filename, ".*"), ".pem"])
  file.write(content)
  file.rewind
  Rack::Test::UploadedFile.new(file.path, "application/x-pem-file", original_filename: filename)
end

def stub_github_installation(transport, permissions)
  transport.stub_json("GET", "https://api.github.com/app/installations/456",
                      body: { "id" => 456, "permissions" => permissions })
end

def stub_discord_me(transport)
  transport.stub_json("GET", "https://discord.com/api/v10/users/@me",
                      body: { "id" => "130000000000000001", "username" => "bot" })
end

def seed_github_account(key: accounts_pem)
  account = GithubAppsAccount.current
  account.update!(app_id: "123", installation_id: "456", api_url: "")
  account.private_key = key
  account.save!
  account
end

def seed_discord_account(token: "accounts-bot-token")
  account = DiscordAccount.current
  account.bot_token = token
  account.save!
  account
end

test("accounts index shows both providers, health states, and the API key section") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/accounts"
    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    %w[GitHub\ Apps Discord 管理APIキー 接続確認する 保存する].each do |text|
      expect(body.include?(text)).to eq(true)
    end
    expect(body.include?("未確認")).to eq(true)
    expect(body.include?("未発行")).to eq(true)
  end
end

test("github save stores the uploaded key encrypted and shows only the fingerprint") do |http:|
  AdminTestSupport.as_admin(http) do
    key_text = accounts_pem
    http.patch "/admin/accounts/github",
      { github_apps_account: { app_id: " 123 ", installation_id: "456", api_url: "",
                               private_key_file: accounts_upload(key_text) } }
    expect(http.last_response.status).to eq(302)

    account = GithubAppsAccount.ordered.first
    expect(account.app_id).to eq("123")
    expect(account.configured?).to eq(true)
    expect(account.private_key).to eq(key_text.strip)
    expect(account.encrypted_private_key).not_to include("PRIVATE KEY")
    expect(account.private_key_fingerprint).to start_with("sha256:")

    http.get "/admin/accounts"
    body = http.last_response.body
    expect(body.include?(account.private_key_fingerprint)).to eq(true)
    expect(body.include?("PRIVATE KEY")).to eq(false)
    expect(body.include?(key_text.lines.first.strip)).to eq(false)
  end
end

test("github save rejects non-key files and invalid fields without persisting") do |http:|
  AdminTestSupport.as_admin(http) do
    http.patch "/admin/accounts/github",
      { github_apps_account: { app_id: "123", installation_id: "456",
                               private_key_file: accounts_upload("not-a-key") } }
    expect(http.last_response.status).to eq(422)
    expect(GithubAppsAccount.ordered.first.private_key?).to eq(false)

    http.patch "/admin/accounts/github",
      { github_apps_account: { app_id: "abc", installation_id: "456" } }
    expect(http.last_response.status).to eq(422)

    http.patch "/admin/accounts/github",
      { github_apps_account: { app_id: "123", installation_id: "456",
                               api_url: "http://insecure.example.invalid" } }
    expect(http.last_response.status).to eq(422)
    expect(GithubAppsAccount.ordered.first.api_url).to eq("")
  end
end

test("discord save stores the token encrypted and blank keeps the stored value") do |http:|
  AdminTestSupport.as_admin(http) do
    http.patch "/admin/accounts/discord", { discord_account: { bot_token: "first-token" } }
    expect(http.last_response.status).to eq(302)
    account = DiscordAccount.ordered.first
    expect(account.configured?).to eq(true)
    expect(account.encrypted_bot_token).not_to include("first-token")

    http.patch "/admin/accounts/discord", { discord_account: { bot_token: "" } }
    expect(http.last_response.status).to eq(302)
    expect(account.reload.bot_token).to eq("first-token")

    http.get "/admin/accounts"
    expect(http.last_response.body.include?("first-token")).to eq(false)

    http.patch "/admin/accounts/discord", { discord_account: { bot_token: "", clear_token: "1" } }
    expect(http.last_response.status).to eq(302)
    expect(account.reload.configured?).to eq(false)
  end
end

test("accounts writes require a CSRF token when protection is enabled") do |http:|
  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.get "/admin/accounts"
      body = http.last_response.body
      form = body[/<form action="\/admin\/accounts\/discord".*?<\/form>/m]
      token = form[/name="authenticity_token" value="([^"]+)"/, 1]
      expect(token.nil?).to eq(false)

      http.patch "/admin/accounts/discord", { discord_account: { bot_token: "forged" } }
      expect(http.last_response.status).to eq(422)
      expect(DiscordAccount.ordered.first.configured?).to eq(false)

      http.patch "/admin/accounts/discord",
        { discord_account: { bot_token: "genuine" }, authenticity_token: token }
      expect(http.last_response.status).to eq(302)
      expect(DiscordAccount.ordered.first.configured?).to eq(true)
    end
  end
end

test("github health check records ok with the check time, then surfaces missing permissions") do |http:|
  AdminTestSupport.as_admin(http) do
    seed_github_account
    transport = accounts_transport
    stub_github_installation(transport,
      { "issues" => "write", "pull_requests" => "write", "actions" => "read", "metadata" => "read" })
    AccountsHealthCheck.test_transport = transport

    http.post "/admin/accounts/health_check", { provider: "github" }
    expect(http.last_response.status).to eq(302)
    state = GithubAppsAccount.ordered.first.health_check_state
    expect(state.status).to eq("ok")
    expect(state.error_code).to be_nil
    expect(state.updated_at).not_to be_nil
    expect(GithubAppsHealthCheckState.column_names.include?("created_at")).to eq(false)

    transport2 = accounts_transport
    stub_github_installation(transport2, { "issues" => "read", "metadata" => "read" })
    AccountsHealthCheck.test_transport = transport2
    http.post "/admin/accounts/health_check", { provider: "github" }
    expect(http.last_response.status).to eq(302)
    state = GithubAppsAccount.ordered.first.health_check_state.reload
    expect(state.status).to eq("error")
    expect(state.error_code).to eq("missing_permissions")

    http.get "/admin/accounts"
    expect(http.last_response.body.include?("不足")).to eq(true)
  end
end

test("discord health check records connectivity and rejects unknown providers") do |http:|
  AdminTestSupport.as_admin(http) do
    seed_discord_account
    transport = accounts_transport
    stub_discord_me(transport)
    AccountsHealthCheck.test_transport = transport

    http.post "/admin/accounts/health_check", { provider: "discord" }
    expect(http.last_response.status).to eq(302)
    state = DiscordAccount.ordered.first.health_check_state
    expect(state.status).to eq("ok")
    expect(DiscordHealthCheckState.column_names.include?("created_at")).to eq(false)

    http.post "/admin/accounts/health_check", { provider: "teams" }
    expect(http.last_response.status).to eq(302)
    expect(DiscordAccount.ordered.first.health_check_state.reload.status).to eq("ok")
  end
end

test("health check without credentials records a safe failure without I/O") do |http:|
  AdminTestSupport.as_admin(http) do
    transport = accounts_transport
    AccountsHealthCheck.test_transport = transport

    http.post "/admin/accounts/health_check", { provider: "github" }
    expect(http.last_response.status).to eq(302)
    state = GithubAppsAccount.ordered.first.health_check_state
    expect(state.status).to eq("error")
    expect(state.error_code).to eq("credentials_missing")
    expect(transport.requests).to eq([])
  end
end

test("API token rotation shows plaintext once and invalidates the old token") do |http:|
  AdminTestSupport.as_admin(http) do
    http.post "/admin/accounts/rotate_api_token"
    expect(http.last_response.status).to eq(302)
    http.get "/admin/accounts"
    shown = http.last_response.body[/id="rotated-api-token">([^<]+)</, 1]
    expect(shown.nil?).to eq(false)
    expect(shown.size >= 32).to eq(true)
    expect(AdminApiToken.current.matches?(shown)).to eq(true)
    expect(AdminApiToken.current.matches?("wrong-token")).to eq(false)

    http.get "/admin/accounts"
    expect(http.last_response.body.include?(shown)).to eq(false)
  end
end

test("API token authenticates requests and rotation invalidates the old token") do |http:|
  AdminTestSupport.as_admin(http) do
    http.post "/admin/accounts/rotate_api_token"
    http.get "/admin/accounts"
    first = http.last_response.body[/id="rotated-api-token">([^<]+)</, 1]
    http.post "/admin/accounts/rotate_api_token"
    http.get "/admin/accounts"
    second = http.last_response.body[/id="rotated-api-token">([^<]+)</, 1]
    expect(first == second).to eq(false)

    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" }, key: "rotate-1", token: first)
    expect(http.last_response.status).to eq(401)
    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" }, key: "rotate-1", token: second)
    expect(http.last_response.status).to eq(202)
  end
end

test("accounts models keep secrets out of inspection and serialization") do |http:|
  AdminTestSupport.as_admin(http) do
    github = seed_github_account
    discord = seed_discord_account(token: "inspect-me-not")
    _record, plaintext = AdminApiToken.rotate!

    expect(github.inspect.include?("PRIVATE KEY")).to eq(false)
    expect(discord.inspect.include?("inspect-me-not")).to eq(false)
    expect(github.serializable_hash.key?("encrypted_private_key")).to eq(false)
    expect(discord.serializable_hash.key?("encrypted_bot_token")).to eq(false)
    expect(AdminApiToken.current.serializable_hash.key?("token_digest")).to eq(false)
    expect(plaintext.size).to eq(64)
  end
end
