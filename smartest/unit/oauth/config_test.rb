# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/aiconshell/oauth"

def oauth_env(overrides = {})
  {
    "OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client",
    "OAUTH_ATLASSIAN_CLIENT_SECRET" => "atl-secret",
    "OAUTH_ATLASSIAN_CLOUD_ID" => "11111111-2222-3333-4444-555555555555",
    "OAUTH_ATLASSIAN_REDIRECT_URI" => "https://app.example.test/oauth/atlassian/callback",
    "OAUTH_MICROSOFT_CLIENT_ID" => "ms-client",
    "OAUTH_MICROSOFT_CLIENT_SECRET" => "ms-secret",
    "OAUTH_MICROSOFT_TENANT_ID" => "test-tenant",
    "OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback"
  }.merge(overrides)
end

test("missing env names never expose values") do
  config = Aiconshell::Oauth::Config.new(env: {})

  expect(config.missing_env_names("atlassian")).to eq(
    %w[OAUTH_ATLASSIAN_CLIENT_ID OAUTH_ATLASSIAN_CLIENT_SECRET
       OAUTH_ATLASSIAN_CLOUD_ID OAUTH_ATLASSIAN_REDIRECT_URI]
  )
  expect(config.missing_env_names("microsoft")).to eq(
    %w[OAUTH_MICROSOFT_CLIENT_ID OAUTH_MICROSOFT_CLIENT_SECRET
       OAUTH_MICROSOFT_TENANT_ID OAUTH_MICROSOFT_REDIRECT_URI]
  )
  expect(config.missing_env_names("atlassian").join.include?("secret-value")).to eq(false)
end

test("secret file fallback counts as configured") do
  require "tempfile"
  secret_file = Tempfile.new("oauth-secret")
  secret_file.write("file-secret-value\n")
  secret_file.flush
  config = Aiconshell::Oauth::Config.new(env: oauth_env(
    "OAUTH_ATLASSIAN_CLIENT_SECRET" => "",
    "OAUTH_MICROSOFT_CLIENT_SECRET" => "",
    "OAUTH_ATLASSIAN_CLIENT_SECRET_FILE" => secret_file.path,
    "OAUTH_MICROSOFT_CLIENT_SECRET_FILE" => secret_file.path
  ))

  expect(config.missing_env_names("atlassian")).to eq([])
  expect(config.missing_env_names("microsoft")).to eq([])
  expect(config.atlassian.client_secret).to eq("file-secret-value")
  expect(config.microsoft.client_secret).to eq("file-secret-value")
ensure
  secret_file.close! if defined?(secret_file) && secret_file
end

test("fixed endpoints cannot be chosen by callers") do
  config = Aiconshell::Oauth::Config.new(env: oauth_env)

  expect(config.token_url("atlassian")).to eq("https://auth.atlassian.com/oauth/token")
  expect(config.token_url("microsoft")).to eq("https://login.microsoftonline.com/test-tenant/oauth2/v2.0/token")
  expect(config.authorize_url("microsoft")).to eq("https://login.microsoftonline.com/test-tenant/oauth2/v2.0/authorize")
  expect(config.graph_me_url).to eq("https://graph.microsoft.com/v1.0/me")

  raised = nil
  begin
    config.token_url("evil")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
end

test("required scopes match the official delegated sets") do
  expect(Aiconshell::Oauth::Config::ATLASSIAN_REQUIRED_SCOPES).to eq(
    %w[offline_access read:jira-work write:jira-work read:jira-user]
  )
  expect(Aiconshell::Oauth::Config::MICROSOFT_REQUIRED_SCOPES).to eq(
    %w[offline_access User.Read ChannelMessage.Read.All ChannelMessage.Send Chat.Read ChatMessage.Send]
  )
end

test("redirect URIs must be https without userinfo or fragment") do
  config = Aiconshell::Oauth::Config.new(env: {})

  expect(config.valid_redirect_uri?("https://app.example.test/oauth/callback")).to eq(true)
  expect(config.valid_redirect_uri?("http://app.example.test/oauth/callback")).to eq(false)
  expect(config.valid_redirect_uri?("http://localhost:3000/oauth/callback")).to eq(true)
  expect(config.valid_redirect_uri?("https://user:pass@app.example.test/cb")).to eq(false)
  expect(config.valid_redirect_uri?("https://app.example.test/cb#fragment")).to eq(false)
  expect(config.valid_redirect_uri?("not a url")).to eq(false)
  expect(config.valid_redirect_uri?("")).to eq(false)
  expect(config.valid_redirect_uri?(nil)).to eq(false)
end
