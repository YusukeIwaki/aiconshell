# frozen_string_literal: true

require "db_helper"
require_relative "oauth_test_support"

test("atlassian normal callback connects with verified principal and scopes") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  expect(begun["authorize_url"].start_with?("https://auth.atlassian.com/authorize?")).to eq(true)
  expect(begun["state"].empty?).to eq(false)

  attempt = OauthAuthAttempt.last
  expect(attempt.state_digest.include?(begun["state"])).to eq(false)
  expect(attempt.encrypted_code_verifier.nil?).to eq(true)
  expect(attempt.generation_at_start).to eq(0)

  OauthTestSupport.script_atlassian_callback(ctx[:transport])
  connection = ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                                   code: "auth-code-1", browser_session_id: "sess-1")

  expect(connection.state).to eq("connected")
  expect(connection.external_principal).to eq("acc-123")
  expect(connection.display_name).to eq("Atlassian User")
  expect(connection.cloud_id).to eq(OauthTestSupport::CLOUD_ID)
  # First success also bumps the generation (0 -> 1) so a delayed second
  # attempt with generation_at_start=0 cannot replace it (issue #22 review).
  expect(connection.generation).to eq(1)
  expect(connection.encrypted_access_token.include?("at-1")).to eq(false)
  expect(ctx[:store].decrypt(connection.encrypted_access_token)).to eq("at-1")
  expect(ctx[:store].decrypt(connection.encrypted_refresh_token)).to eq("rt-1")
  expect(OauthAuthAttempt.last.status).to eq("succeeded")
  expect(OauthAuthAttempt.last.encrypted_code_verifier.nil?).to eq(true)
  ctx[:transport].assert_consumed!
end

test("microsoft normal callback consumes the PKCE verifier once") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")
  expect(begun["authorize_url"]).to match(%r{\Ahttps://login\.microsoftonline\.com/test-tenant/oauth2/v2\.0/authorize\?})
  expect(OauthAuthAttempt.last.encrypted_code_verifier.nil?).to eq(false)

  OauthTestSupport.script_microsoft_callback(ctx[:transport])
  connection = ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                                   code: "auth-code-9", browser_session_id: "sess-1")

  expect(connection.state).to eq("connected")
  expect(connection.external_principal).to eq("user-oid-1")
  expect(connection.tenant_id).to eq("test-tenant")
  expect(connection.generation).to eq(1)
  ctx[:transport].assert_consumed!
end

test("callback with the wrong browser session is rejected without consuming") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-owner")
  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "sess-attacker")
  rescue Aiconshell::Oauth::StateInvalid => e
    raised = e
  end
  expect(raised.code).to eq("state_mismatch")
  expect(OauthAuthAttempt.last.status).to eq("pending")
  expect(OauthConnection.count).to eq(0)
  expect(ctx[:transport].requests.size).to eq(0)
end

test("double callback is rejected: the second use fails") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  OauthTestSupport.script_atlassian_callback(ctx[:transport])
  ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                      code: "auth-code-1", browser_session_id: "sess-1")

  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::StateInvalid => e
    raised = e
  end
  expect(raised.code).to eq("state_mismatch")
  expect(ctx[:transport].requests_to("https://auth.atlassian.com/oauth/token", method: :POST).size).to eq(1)
  ctx[:transport].assert_consumed!
end

test("expired attempts fail without network or connection") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")
  OauthAuthAttempt.last.update!(expires_at: 1.second.ago)

  raised = nil
  begin
    ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::StateInvalid => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthAuthAttempt.last.status).to eq("expired")
  expect(OauthConnection.count).to eq(0)
  expect(ctx[:transport].requests.size).to eq(0)
end

test("scope and cloud mismatches keep the healthy connection intact") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  healthy = OauthTestSupport.connect(ctx, "atlassian")
  first_tokens = [healthy.encrypted_access_token, healthy.encrypted_refresh_token]

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-2")
  ctx[:transport].expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: {
    "access_token" => "at-2", "refresh_token" => "rt-2",
    "expires_in" => 3600, "scope" => OauthTestSupport::ATLASSIAN_SCOPES, "token_type" => "Bearer"
  })
  ctx[:transport].expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
    { "id" => OauthTestSupport::CLOUD_ID, "name" => "Test", "scopes" => ["read:jira-work"] }
  ])
  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-2", browser_session_id: "sess-2")
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("scope_mismatch")

  kept = OauthConnection.find_by(provider: "atlassian")
  expect(kept.state).to eq("connected")
  expect(kept.generation).to eq(1)
  expect(kept.external_principal).to eq("acc-123")
  expect([kept.encrypted_access_token, kept.encrypted_refresh_token]).to eq(first_tokens)
  expect(OauthAuthAttempt.last.status).to eq("failed")
  ctx[:transport].assert_consumed!
end

test("denied consent ends the attempt without touching the connection") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "microsoft")

  begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "sess-2")
  raised = nil
  begin
    ctx[:auth].callback(provider: "microsoft", state: begun["state"], code: nil,
                        browser_session_id: "sess-2", error: "access_denied")
  rescue Aiconshell::Oauth::StateInvalid => e
    raised = e
  end
  expect(raised.code).to eq("access_denied")
  expect(OauthConnection.find_by(provider: "microsoft").state).to eq("connected")
  expect(ctx[:transport].requests.size).to eq(2 + 0) # connect used 2; denial adds none
  expect(OauthAuthAttempt.last.status).to eq("failed")
end

test("authorization codes are never persisted") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  OauthTestSupport.script_atlassian_callback(ctx[:transport])
  ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                      code: "auth-code-super-secret", browser_session_id: "sess-1")

  columns = (OauthAuthAttempt.column_names + OauthConnection.column_names).join(" ")
  expect(columns.include?("auth_code")).to eq(false)
  dumped = (OauthAuthAttempt.all.map(&:attributes) + OauthConnection.all.map(&:attributes)).inspect
  expect(dumped.include?("auth-code-super-secret")).to eq(false)
  expect(dumped.include?(begun["state"])).to eq(false)
  ctx[:transport].assert_consumed!
end

test("secrets stay out of inspection, serialization, and event data") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  connection = OauthTestSupport.connect(ctx, "atlassian")

  expect(connection.inspect.include?("at-1")).to eq(false)
  expect(connection.inspect.include?("rt-1")).to eq(false)
  serialized = connection.serializable_hash.merge(connection.as_json)
  expect(serialized.keys).not_to include("encrypted_access_token")
  expect(serialized.keys).not_to include("encrypted_refresh_token")
  expect(serialized.inspect.include?("at-1")).to eq(false)

  attempt_shown = OauthAuthAttempt.last.inspect
  expect(attempt_shown.include?("state_digest") || attempt_shown).to eq(attempt_shown)

  sink_dump = ctx[:sink].events.inspect
  expect(sink_dump.include?("at-1")).to eq(false)
  expect(sink_dump.include?("rt-1")).to eq(false)
  expect(sink_dump.include?("auth-code-1")).to eq(false)
  kinds = ctx[:sink].kinds
  expect(kinds.include?("oauth.authorize_started")).to eq(true)
  expect(kinds.include?("oauth.callback_succeeded")).to eq(true)
  ctx[:transport].assert_consumed!
end

test("unique constraints guard state digests and providers") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")

  duplicate = nil
  begin
    OauthAuthAttempt.create!(
      provider: "atlassian", state_digest: OauthAuthAttempt.last.state_digest,
      browser_session_digest: "x", redirect_uri: "https://app.example.test/x",
      status: "pending", expires_at: 10.minutes.from_now
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    duplicate = e
  end
  expect(duplicate.nil?).to eq(false)
  # The DB unique indexes are the backstop behind the model validations.
  attempt_indexes = OauthAuthAttempt.connection.indexes(:oauth_auth_attempts).select(&:unique).map(&:columns)
  expect(attempt_indexes.any? { |cols| cols.include?("state_digest") }).to eq(true)
  connection_indexes = OauthConnection.connection.indexes(:oauth_connections).select(&:unique).map(&:columns)
  expect(connection_indexes.any? { |cols| cols.include?("provider") }).to eq(true)

  clash = nil
  begin
    OauthConnection.create!(provider: "atlassian", state: "connected")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    clash = e
  end
  expect(clash.nil?).to eq(false)
  ctx[:transport].assert_consumed!
end

test("unconfigured providers fail safe without rows") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services(env: {})

  raised = nil
  begin
    ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::ConfigMissing => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(OauthAuthAttempt.count).to eq(0)

  status = ctx[:auth].public_status(provider: "microsoft")
  expect(status["state"]).to eq("unknown")
  expect(status["configured"]).to eq(false)
  expect(status.keys).not_to include("encrypted_access_token")
end
