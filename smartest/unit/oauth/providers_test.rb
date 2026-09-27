# frozen_string_literal: true

require "test_helper"
require "uri"
require_relative "../../../lib/aiconshell/oauth"
require_relative "../../support/boundary_fixtures"

CLOUD_ID = "11111111-2222-3333-4444-555555555555"
ATLASSIAN_ENV = {
  "OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client",
  "OAUTH_ATLASSIAN_CLIENT_SECRET" => "atl-secret",
  "OAUTH_ATLASSIAN_CLOUD_ID" => CLOUD_ID,
  "OAUTH_ATLASSIAN_REDIRECT_URI" => "https://app.example.test/oauth/atlassian/callback"
}.freeze
MICROSOFT_ENV = {
  "OAUTH_MICROSOFT_CLIENT_ID" => "ms-client",
  "OAUTH_MICROSOFT_CLIENT_SECRET" => "ms-secret",
  "OAUTH_MICROSOFT_TENANT_ID" => "test-tenant",
  "OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback"
}.freeze
ATLASSIAN_SCOPES = "offline_access read:jira-work write:jira-work read:jira-user"
MICROSOFT_SCOPES = "offline_access User.Read ChannelMessage.Read.All ChannelMessage.Send Chat.Read ChatMessage.Send"

def atlassian_config
  Aiconshell::Oauth::Config.new(env: ATLASSIAN_ENV)
end

def microsoft_config
  Aiconshell::Oauth::Config.new(env: MICROSOFT_ENV)
end

def atlassian_token_body
  { "access_token" => "at-1", "refresh_token" => "rt-1",
    "expires_in" => 3600, "scope" => ATLASSIAN_SCOPES, "token_type" => "Bearer" }
end

def microsoft_token_body
  { "access_token" => "ms-at-1", "refresh_token" => "ms-rt-1",
    "expires_in" => 3600, "scope" => MICROSOFT_SCOPES, "token_type" => "Bearer" }
end

test("atlassian authorize carries audience, consent, and scopes without PKCE") do
  url = Aiconshell::Oauth::Atlassian.authorize_url(config: atlassian_config, state: "state-123")
  uri = URI.parse(url)
  params = URI.decode_www_form(uri.query).to_h

  expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://auth.atlassian.com/authorize")
  expect(params["audience"]).to eq("api.atlassian.com")
  expect(params["client_id"]).to eq("atl-client")
  expect(params["scope"]).to eq(ATLASSIAN_SCOPES)
  expect(params["redirect_uri"]).to eq("https://app.example.test/oauth/atlassian/callback")
  expect(params["state"]).to eq("state-123")
  expect(params["response_type"]).to eq("code")
  expect(params["prompt"]).to eq("consent")
  expect(params.key?("code_challenge")).to eq(false)
  expect(params.key?("code_challenge_method")).to eq(false)
end

test("microsoft authorize carries tenant, PKCE S256, and consent") do
  url = Aiconshell::Oauth::Microsoft.authorize_url(
    config: microsoft_config, state: "state-456", challenge: "challenge-789"
  )
  uri = URI.parse(url)
  params = URI.decode_www_form(uri.query).to_h

  expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(
    "https://login.microsoftonline.com/test-tenant/oauth2/v2.0/authorize"
  )
  expect(params["client_id"]).to eq("ms-client")
  expect(params["scope"]).to eq(MICROSOFT_SCOPES)
  expect(params["code_challenge"]).to eq("challenge-789")
  expect(params["code_challenge_method"]).to eq("S256")
  expect(params["prompt"]).to eq("consent")
  expect(params["response_type"]).to eq("code")
end

test("atlassian exchange posts JSON to the fixed token URL and validates the shape") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: atlassian_token_body)

  tokens = Aiconshell::Oauth::Atlassian.exchange_code(
    transport: transport, config: atlassian_config,
    code: "auth-code-1", redirect_uri: "https://app.example.test/oauth/atlassian/callback"
  )

  expect(tokens["access_token"]).to eq("at-1")
  expect(tokens["refresh_token"]).to eq("rt-1")
  expect(tokens["expires_in"]).to eq(3600)
  posted = transport.requests_to("https://auth.atlassian.com/oauth/token", method: :POST)
  expect(posted.size).to eq(1)
  expect(posted.first[:body].include?("auth-code-1")).to eq(true)
  transport.assert_consumed!
end

test("exchange rejects empty tokens and non-positive lifetimes") do
  bad_bodies = [
    { "access_token" => "", "expires_in" => 3600 },
    { "access_token" => "at-1", "expires_in" => 0 },
    { "access_token" => "at-1", "expires_in" => -5 },
    { "access_token" => "at-1", "expires_in" => "soon" },
    { "nope" => true }
  ]
  bad_bodies.each do |body|
    transport = BoundaryFixtures::HttpTransport.new
    transport.expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: body)

    raised = nil
    begin
      Aiconshell::Oauth::Atlassian.exchange_code(
        transport: transport, config: atlassian_config,
        code: "code-x", redirect_uri: "https://app.example.test/oauth/atlassian/callback"
      )
    rescue Aiconshell::Oauth::ProviderError => e
      raised = e
    end
    expect(raised.nil?).to eq(false)
    expect(raised.code).to eq("unexpected_response")
    transport.assert_consumed!
  end
end

test("atlassian verify checks the fixed cloud, scopes, and same-cloud principal") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => "other-cloud-id", "name" => "Other",
      "scopes" => ["read:jira-work"], "avatarUrl" => "https://example.test/a.png" },
    { "id" => CLOUD_ID, "name" => "Test",
      "scopes" => %w[offline_access read:jira-work write:jira-work read:jira-user],
      "avatarUrl" => "https://example.test/b.png" }
  ])
  transport.expect_json(:GET, "https://api.atlassian.com/ex/jira/#{CLOUD_ID}/rest/api/3/myself", body: {
    "accountId" => "acc-123", "displayName" => "Test User", "emailAddress" => "t@example.test"
  })

  verified = Aiconshell::Oauth::Atlassian.verify_connection(
    transport: transport, config: atlassian_config, access_token: "at-1"
  )

  expect(verified["principal"]).to eq("acc-123")
  expect(verified["display_name"]).to eq("Test User")
  expect(verified["cloud_id"]).to eq(CLOUD_ID)
  expect(verified["scopes"]).to eq(ATLASSIAN_SCOPES)
  transport.assert_consumed!
end

test("atlassian verify rejects unknown clouds, missing scopes, and empty principals") do
  missing_cloud = BoundaryFixtures::HttpTransport.new
  missing_cloud.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => "other-cloud", "name" => "Other", "scopes" => ["offline_access"] }
  ])
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.verify_connection(
      transport: missing_cloud, config: atlassian_config, access_token: "at-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("cloud_mismatch")
  missing_cloud.assert_consumed!

  thin_scopes = BoundaryFixtures::HttpTransport.new
  thin_scopes.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => CLOUD_ID, "name" => "Test", "scopes" => ["read:jira-work"] }
  ])
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.verify_connection(
      transport: thin_scopes, config: atlassian_config, access_token: "at-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("scope_mismatch")
  thin_scopes.assert_consumed!

  no_principal = BoundaryFixtures::HttpTransport.new
  no_principal.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => CLOUD_ID, "name" => "Test",
      "scopes" => %w[offline_access read:jira-work write:jira-work read:jira-user] }
  ])
  no_principal.expect_json(:GET, "https://api.atlassian.com/ex/jira/#{CLOUD_ID}/rest/api/3/myself", body: {
    "displayName" => "Nameless"
  })
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.verify_connection(
      transport: no_principal, config: atlassian_config, access_token: "at-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("principal_mismatch")
  no_principal.assert_consumed!
end

test("microsoft verify trusts graph /me, never token claims") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
    "id" => "user-oid-1", "displayName" => "MS User",
    "userPrincipalName" => "u@example.test", "mail" => "evil-spoof@example.test"
  })

  verified = Aiconshell::Oauth::Microsoft.verify_connection(
    transport: transport, config: microsoft_config,
    access_token: "ms-at-1", granted_scope: MICROSOFT_SCOPES
  )

  expect(verified["principal"]).to eq("user-oid-1")
  expect(verified["display_name"]).to eq("MS User")
  expect(verified["tenant_id"]).to eq("test-tenant")
  transport.assert_consumed!
end

test("microsoft verify rejects missing principal and thin scopes") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: { "displayName" => "Nobody" })

  raised = nil
  begin
    Aiconshell::Oauth::Microsoft.verify_connection(
      transport: transport, config: microsoft_config,
      access_token: "ms-at-1", granted_scope: MICROSOFT_SCOPES
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("principal_mismatch")
  transport.assert_consumed!

  thin = BoundaryFixtures::HttpTransport.new
  thin.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
    "id" => "user-oid-1", "displayName" => "MS User"
  })
  raised = nil
  begin
    Aiconshell::Oauth::Microsoft.verify_connection(
      transport: thin, config: microsoft_config,
      access_token: "ms-at-1", granted_scope: "offline_access User.Read"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("scope_mismatch")
  thin.assert_consumed!
end

test("transport failures classify without exposing provider text") do
  timeout_transport = BoundaryFixtures::HttpTransport.new
  timeout_transport.expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::TransportTimeout.new(http_method: "POST", url: "https://auth.atlassian.com/oauth/token", timeout_kind: "read")
  )
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.refresh(
      transport: timeout_transport, config: atlassian_config, refresh_token: "rt-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("timeout")
  timeout_transport.assert_consumed!

  limited_transport = BoundaryFixtures::HttpTransport.new
  limited_transport.expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::RateLimited.new(status: 429, http_method: "POST", url: "https://auth.atlassian.com/oauth/token")
  )
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.refresh(
      transport: limited_transport, config: atlassian_config, refresh_token: "rt-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("rate_limited")
  limited_transport.assert_consumed!

  revoked_transport = BoundaryFixtures::HttpTransport.new
  revoked_transport.expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::HttpError.new(status: 400, http_method: "POST", url: "https://auth.atlassian.com/oauth/token")
  )
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.refresh(
      transport: revoked_transport, config: atlassian_config, refresh_token: "rt-old"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("invalid_grant")
  revoked_transport.assert_consumed!

  broken_transport = BoundaryFixtures::HttpTransport.new
  broken_transport.expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::HttpError.new(status: 500, http_method: "POST", url: "https://auth.atlassian.com/oauth/token")
  )
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.refresh(
      transport: broken_transport, config: atlassian_config, refresh_token: "rt-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("provider_error")
  broken_transport.assert_consumed!
end

test("non-JSON provider output never leaks server text") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_response(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::Http::Response.new(status: 200, headers: {}, body: "<html>secret-server-text</html>")
  )

  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.exchange_code(
      transport: transport, config: atlassian_config,
      code: "code-1", redirect_uri: "https://app.example.test/oauth/atlassian/callback"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("unexpected_response")
  expect(raised.message.include?("secret-server-text")).to eq(false)
  transport.assert_consumed!
end
