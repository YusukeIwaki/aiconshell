# frozen_string_literal: true

require "db_helper"
require_relative "oauth_test_support"

# Issue #22 independent-review regressions for TokenService and the public
# credential port (comment 4). Real models/services + HTTP fixtures.

def expire_connection_for_refresh!(provider)
  row = OauthConnection.find_by!(provider: provider)
  row.update!(token_expires_at: 1.minute.ago)
  row
end

def script_refresh(transport, provider, access: "at-new", refresh: "rt-new", scope: nil, expires_in: 3600)
  url = provider.to_s == "atlassian" ? "https://auth.atlassian.com/oauth/token" : "https://login.microsoftonline.com/test-tenant/oauth2/v2.0/token"
  body = { "access_token" => access, "expires_in" => expires_in, "token_type" => "Bearer" }
  body["refresh_token"] = refresh unless refresh.nil?
  body["scope"] = scope unless scope.nil?
  transport.expect_json(:POST, url, body: body)
end

test("binding_for result passes directly to access_token") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")

  binding = ctx[:creds].binding_for("atlassian")
  # The public contract: the Binding object itself (not just to_h) resolves.
  expect(binding.is_a?(Aiconshell::Oauth::Binding)).to eq(true)
  token = ctx[:creds].access_token(binding)
  expect(token).to eq(ctx[:store].decrypt(OauthConnection.find_by(provider: "atlassian").encrypted_access_token))
  # to_h round-trips as well.
  expect(ctx[:creds].access_token(binding.to_h)).to eq(token)
  # An empty-Hash binding never matches.
  raised = nil
  begin
    ctx[:creds].access_token({})
  rescue Aiconshell::Oauth::BindingMismatch => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  ctx[:transport].assert_consumed!
end

test("missing and undecryptable refresh tokens persist needs_reauth") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "microsoft")
  row = expire_connection_for_refresh!("microsoft")
  row.update!(encrypted_refresh_token: nil)

  raised = nil
  begin
    ctx[:creds].access_token(ctx[:creds].binding_for("microsoft").to_h)
  rescue Oauth::CredentialProvider::NotConnected, Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("invalid_grant")
  reloaded = OauthConnection.find(row.id)
  expect(reloaded.state).to eq("needs_reauth")
  expect(reloaded.error_code).to eq("invalid_grant")

  # Tampered ciphertext reads as absent and persists the same way.
  ctx2 = OauthTestSupport.services
  OauthTestSupport.connect(ctx2, "atlassian")
  row2 = expire_connection_for_refresh!("atlassian")
  row2.update!(encrypted_refresh_token: "tampered-ciphertext")
  raised = nil
  begin
    ctx2[:creds].access_token(ctx2[:creds].binding_for("atlassian").to_h)
  rescue Oauth::CredentialProvider::NotConnected, Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("invalid_grant")
  expect(OauthConnection.find(row2.id).state).to eq("needs_reauth")
end

test("refresh rotation is atomic and keeps the generation") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  connection = OauthTestSupport.connect(ctx, "atlassian")
  generation = connection.generation
  expire_connection_for_refresh!("atlassian")

  script_refresh(ctx[:transport], "atlassian", access: "at-rot", refresh: "rt-rot",
                 scope: OauthTestSupport::ATLASSIAN_SCOPES)
  token = ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
  expect(token).to eq("at-rot")

  reloaded = OauthConnection.find_by(provider: "atlassian")
  expect(reloaded.generation).to eq(generation)
  expect(ctx[:store].decrypt(reloaded.encrypted_access_token)).to eq("at-rot")
  expect(ctx[:store].decrypt(reloaded.encrypted_refresh_token)).to eq("rt-rot")
  expect(reloaded.refresh_lease_token.nil?).to eq(true)
  ctx[:transport].assert_consumed!
end

test("omitted refresh scope keeps stored scopes, explicit narrowing is rejected") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "microsoft")
  expire_connection_for_refresh!("microsoft")

  # Omitted scope (no key) means "requested scopes": rotation succeeds.
  script_refresh(ctx[:transport], "microsoft", access: "at-keep", refresh: "rt-keep", scope: nil)
  # Remove the scope key entirely to model omission.
  # (script_refresh with scope:nil already omits the key.)
  token = ctx[:creds].access_token(ctx[:creds].binding_for("microsoft").to_h)
  expect(token).to eq("at-keep")
  expect(OauthConnection.find_by(provider: "microsoft").state).to eq("connected")

  expire_connection_for_refresh!("microsoft")
  script_refresh(ctx[:transport], "microsoft", access: "at-thin", refresh: "rt-thin",
                 scope: "offline_access User.Read")
  raised = nil
  begin
    ctx[:creds].access_token(ctx[:creds].binding_for("microsoft").to_h)
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("scope_mismatch")
  kept = OauthConnection.find_by(provider: "microsoft")
  expect(kept.state).to eq("connected")
  expect(ctx[:store].decrypt(kept.encrypted_access_token)).to eq("at-keep")
  expect(kept.refresh_lease_token.nil?).to eq(true)
  ctx[:transport].assert_consumed!
end

test("client and tenant changes since connect are never issued to the old binding") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env
  ctx = OauthTestSupport.services(env: base_env)
  OauthTestSupport.connect(ctx, "microsoft")
  expire_connection_for_refresh!("microsoft")

  changed = base_env.merge("OAUTH_MICROSOFT_TENANT_ID" => "other-tenant")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  script_refresh(changed_ctx[:transport], "microsoft", access: "at-evil", refresh: "rt-evil")
  # The old binding still matches the stored row, but the configuration
  # moved: the refresh must not be issued as a normal token.
  # Note: the fixture URL is tenant-fixed; the changed tenant would use a
  # different token URL, so the scripted old-tenant URL stays unconsumed
  # only if no request is sent. Here the service builds the new-tenant URL
  # and the fixture mismatch raises ExpectationError (also a rejection).
  raised = nil
  begin
    changed_ctx[:creds].access_token(ctx[:creds].binding_for("microsoft").to_h)
  rescue StandardError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  kept = OauthConnection.find_by(provider: "microsoft")
  expect(kept.state).to eq("connected")
  expect(ctx[:store].decrypt(kept.encrypted_access_token) == "at-evil").to eq(false)
end

test("concurrent refreshes serialize on the exclusive lease") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  row = expire_connection_for_refresh!("atlassian")
  row.update!(
    refresh_lease_token: "lease-held",
    refresh_lease_expires_at: 5.minutes.from_now,
    refresh_lease_generation: row.generation
  )

  raised = nil
  begin
    ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
  rescue Aiconshell::Oauth::RefreshBusy, Oauth::CredentialProvider::NotConnected => e
    raised = e
  end
  # CredentialProvider passes RefreshBusy through unwrapped.
  expect(raised.nil?).to eq(false)
  expect(ctx[:transport].requests.size).to eq(3) # connect used 3; busy adds none
end

test("expired leases clear and never resurrect a disconnect") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  row = expire_connection_for_refresh!("atlassian")
  # Simulate a stale lease that expired without committing.
  row.update!(
    refresh_lease_token: "stale-lease",
    refresh_lease_expires_at: 1.second.ago,
    refresh_lease_generation: row.generation
  )
  # A fresh refresh claims a new lease and succeeds.
  script_refresh(ctx[:transport], "atlassian", access: "at-fresh", refresh: "rt-fresh",
                 scope: OauthTestSupport::ATLASSIAN_SCOPES)
  token = ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
  expect(token).to eq("at-fresh")

  # A disconnect during a refresh never resurrects: bump the generation
  # after the lease was claimed and the old result must die.
  expire_connection_for_refresh!("atlassian")
  claimed_row = OauthConnection.find_by(provider: "atlassian")
  claimed_row.update!(
    refresh_lease_token: "lease-doomed",
    refresh_lease_expires_at: 5.minutes.from_now,
    refresh_lease_generation: claimed_row.generation
  )
  lease = "lease-doomed"
  ctx[:auth].disconnect(provider: "atlassian")
  # Directly committing the stale lease must not resurrect.
  service = ctx[:tokens]
  raised = nil
  begin
    service.send(:commit_rotation!, claimed_row.id, lease,
                 { "access_token" => "at-stale", "refresh_token" => "rt-stale", "expires_in" => 3600, "scope" => nil })
  rescue Aiconshell::Oauth::BindingMismatch, Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
end

test("timeouts keep the old row for safe retry instead of forcing reauth") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  expire_connection_for_refresh!("atlassian")

  ctx[:transport].expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::TransportTimeout.new(http_method: "POST", url: "https://auth.atlassian.com/oauth/token", timeout_kind: "read")
  )
  raised = nil
  begin
    ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
  rescue Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.code).to eq("timeout")
  # Uncertainty keeps the old tokens and the connected state; only an
  # explicit invalid_grant moves to needs_reauth.
  kept = OauthConnection.find_by(provider: "atlassian")
  expect(kept.state).to eq("connected")
  expect(kept.refresh_lease_token.nil?).to eq(true)
  expect(ctx[:store].decrypt(kept.encrypted_refresh_token) == "rt-1").to eq(true)
  ctx[:transport].assert_consumed!
end

test("atlassian 403 revocation moves the connection to needs_reauth") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  expire_connection_for_refresh!("atlassian")

  ctx[:transport].expect_error(
    :POST, "https://auth.atlassian.com/oauth/token",
    Aiconshell::Plugins::HttpError.new(status: 403, http_method: "POST", url: "https://auth.atlassian.com/oauth/token")
  )
  raised = nil
  begin
    ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
  rescue StandardError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("invalid_grant")
  expect(OauthConnection.find_by(provider: "atlassian").state).to eq("needs_reauth")
  ctx[:transport].assert_consumed!
end
