# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/aiconshell/oauth"
require_relative "../../support/boundary_fixtures"

# Independent-review regressions for issue #22 (comments 1-2):
# scope omission vs insufficiency, forbidden tenants, secret inspection,
# Atlassian 403 revocation, and strict provider JSON types.

def review_atlassian_env(overrides = {})
  {
    "OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client",
    "OAUTH_ATLASSIAN_CLIENT_SECRET" => "atl-secret",
    "OAUTH_ATLASSIAN_CLOUD_ID" => "11111111-2222-3333-4444-555555555555",
    "OAUTH_ATLASSIAN_REDIRECT_URI" => "https://app.example.test/oauth/atlassian/callback"
  }.merge(overrides)
end

def review_microsoft_env(overrides = {})
  {
    "OAUTH_MICROSOFT_CLIENT_ID" => "ms-client",
    "OAUTH_MICROSOFT_CLIENT_SECRET" => "ms-secret",
    "OAUTH_MICROSOFT_TENANT_ID" => "test-tenant",
    "OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback"
  }.merge(overrides)
end

REVIEW_CLOUD = "11111111-2222-3333-4444-555555555555"
REVIEW_MS_DELEGATED = "User.Read ChannelMessage.Read.All ChannelMessage.Send Chat.Read ChatMessage.Send"

test("microsoft scope omission means requested scopes, explicit thinning is rejected") do
  config = Aiconshell::Oauth::Config.new(env: review_microsoft_env)
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
    "id" => "user-1", "displayName" => "MS User"
  })
  # Omitted scope (nil) is accepted per the Entra spec.
  verified = Aiconshell::Oauth::Microsoft.verify_connection(
    transport: transport, config: config,
    access_token: "ms-at-1", granted_scope: nil
  )
  expect(verified["principal"]).to eq("user-1")
  expect(verified["scopes"].include?("User.Read")).to eq(true)
  transport.assert_consumed!

  thin = BoundaryFixtures::HttpTransport.new
  thin.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
    "id" => "user-1", "displayName" => "MS User"
  })
  raised = nil
  begin
    Aiconshell::Oauth::Microsoft.verify_connection(
      transport: thin, config: config,
      access_token: "ms-at-1", granted_scope: "offline_access User.Read"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("scope_mismatch")
  thin.assert_consumed!

  # offline_access alone never satisfies the delegated check.
  offline_only = BoundaryFixtures::HttpTransport.new
  offline_only.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
    "id" => "user-1", "displayName" => "MS User"
  })
  raised = nil
  begin
    Aiconshell::Oauth::Microsoft.verify_connection(
      transport: offline_only, config: config,
      access_token: "ms-at-1", granted_scope: "offline_access"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("scope_mismatch")
  offline_only.assert_consumed!
end

test("atlassian accessible-resources without offline_access still connects") do
  config = Aiconshell::Oauth::Config.new(env: review_atlassian_env)
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => REVIEW_CLOUD, "name" => "Test",
      "scopes" => %w[read:jira-work write:jira-work read:jira-user] }
  ])
  transport.expect_json(:GET, "https://api.atlassian.com/ex/jira/#{REVIEW_CLOUD}/rest/api/3/myself", body: {
    "accountId" => "acc-1", "displayName" => "Jira User"
  })
  verified = Aiconshell::Oauth::Atlassian.verify_connection(
    transport: transport, config: config, access_token: "at-1"
  )
  expect(verified["principal"]).to eq("acc-1")
  transport.assert_consumed!
end

test("microsoft fixed tenant rejects common/organizations/consumers") do
  %w[common organizations consumers COMMON Organizations].each do |tenant|
    config = Aiconshell::Oauth::Config.new(env: review_microsoft_env("OAUTH_MICROSOFT_TENANT_ID" => tenant))
    raised = nil
    begin
      config.token_url("microsoft")
    rescue Aiconshell::Oauth::ProviderError => e
      raised = e
    end
    expect(raised.nil?).to eq(false)
    expect(raised.code).to eq("tenant_mismatch")

    raised = nil
    begin
      Aiconshell::Oauth::Microsoft.authorize_url(config: config, state: "s", challenge: "c" * 43)
    rescue Aiconshell::Oauth::ProviderError, Aiconshell::Oauth::ConfigMissing => e
      raised = e
    end
    expect(raised.nil?).to eq(false)
  end
end

test("provider config and secret objects never expose secrets in inspection") do
  config = Aiconshell::Oauth::Config.new(env: review_atlassian_env.merge(review_microsoft_env))
  atl = config.atlassian
  ms = config.microsoft

  [atl.inspect, atl.to_s, config.inspect, config.to_s].each do |shown|
    expect(shown.include?("atl-secret")).to eq(false)
    expect(shown.include?("ms-secret")).to eq(false)
    expect(shown.include?("atl-client")).to eq(false)
  end

  box = Aiconshell::Oauth::SecretBox.new(key: SecureRandom.bytes(32))
  expect(box.inspect.include?("secret")).to eq(false) if false # placeholder
  expect(box.inspect).to eq("#<Aiconshell::Oauth::SecretBox encrypted=true>")
end

test("atlassian 403 refresh maps to invalid_grant without exposing bodies") do
  config = Aiconshell::Oauth::Config.new(env: review_atlassian_env)
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::HttpError.new(status: 403, http_method: "POST", url: "https://auth.atlassian.com/oauth/token")
  )
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.refresh(
      transport: transport, config: config, refresh_token: "rt-old"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("invalid_grant")
  expect(raised.message.include?("invalid_grant") || raised.message.include?("oauth")).to eq(true)
  transport.assert_consumed!
end

test("provider JSON numerics and hashes are never coerced into grants or principals") do
  # Token scope numerics are a shape violation, not a grant.
  [42, 3.14, { "a" => 1 }, ["offline_access"], true].each do |bad_scope|
    raised = nil
    begin
      Aiconshell::Oauth::TokenSet.validate_exchange!(
        { "access_token" => "at-1", "expires_in" => 3600, "scope" => bad_scope },
        provider: "microsoft"
      )
    rescue Aiconshell::Oauth::ProviderError => e
      raised = e
    end
    expect(raised.nil?).to eq(false)
    expect(raised.code).to eq("unexpected_response")
  end
  # Omitted scope stays nil (requested scopes), distinct from explicit thinning.
  omitted = Aiconshell::Oauth::TokenSet.validate_exchange!(
    { "access_token" => "at-1", "expires_in" => 3600 }, provider: "microsoft"
  )
  expect(omitted["scope"].nil?).to eq(true)

  # Numeric principals are rejected, not stringified into normal data.
  atl_config = Aiconshell::Oauth::Config.new(env: review_atlassian_env)
  numeric_principal = BoundaryFixtures::HttpTransport.new
  numeric_principal.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => REVIEW_CLOUD, "name" => "Test",
      "scopes" => %w[read:jira-work write:jira-work read:jira-user] }
  ])
  numeric_principal.expect_json(:GET, "https://api.atlassian.com/ex/jira/#{REVIEW_CLOUD}/rest/api/3/myself", body: {
    "accountId" => 12345, "displayName" => "Numeric"
  })
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.verify_connection(
      transport: numeric_principal, config: atl_config, access_token: "at-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("principal_mismatch")
  numeric_principal.assert_consumed!

  ms_config = Aiconshell::Oauth::Config.new(env: review_microsoft_env)
  numeric_me = BoundaryFixtures::HttpTransport.new
  numeric_me.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
    "id" => 999, "displayName" => "Numeric"
  })
  raised = nil
  begin
    Aiconshell::Oauth::Microsoft.verify_connection(
      transport: numeric_me, config: ms_config,
      access_token: "ms-at-1", granted_scope: nil
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("principal_mismatch")
  numeric_me.assert_consumed!

  # Non-array or non-string scopes are a shape violation.
  bad_scopes = BoundaryFixtures::HttpTransport.new
  bad_scopes.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => REVIEW_CLOUD, "name" => "Test", "scopes" => [42, { "x" => 1 }] }
  ])
  raised = nil
  begin
    Aiconshell::Oauth::Atlassian.verify_connection(
      transport: bad_scopes, config: atl_config, access_token: "at-1"
    )
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("unexpected_response")
  bad_scopes.assert_consumed!
end
