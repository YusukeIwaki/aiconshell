# frozen_string_literal: true

require "db_helper"
require "timeout"
require_relative "oauth_test_support"

# Issue #22 independent-review regressions for TokenService and the public
# credential port (comment 4). Real models/services + HTTP fixtures.

# Transport wrapper that blocks the first refresh POST inside the network
# phase (no DB lock held) until the competing thread has started. Proves
# real claim overlap across separate PG connections with an explicit
# barrier and a finite timeout.
class BlockingRefreshTransport
  def initialize(inner, entered, release)
    @inner = inner
    @entered = entered
    @release = release
    @blocked = false
  end

  def request(method:, url:, headers: {}, body: nil)
    if !@blocked && method.to_s.upcase == "POST" &&
        (url.include?("/oauth/token") || url.include?("/oauth2/v2.0/token"))
      @blocked = true
      @entered << true
      Timeout.timeout(15) { @release.pop }
    end
    @inner.request(method: method, url: url, headers: headers, body: body)
  end

  def method_missing(name, *args, **kwargs, &block)
    @inner.send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @inner.respond_to?(name, include_private)
  end
end

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
  expect(ctx[:transport].requests.size).to eq(2)
  ctx[:transport].assert_consumed!

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
  expect(ctx2[:transport].requests.size).to eq(3)
  ctx2[:transport].assert_consumed!
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

test("valid tokens are never issued after a cloud change, before any HTTP") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env
  ctx = OauthTestSupport.services(env: base_env)
  OauthTestSupport.connect(ctx, "atlassian")
  before_count = ctx[:transport].requests.size
  expect(before_count).to eq(3)

  changed = base_env.merge("OAUTH_ATLASSIAN_CLOUD_ID" => "22222222-3333-4444-5555-666666666666")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  # No refresh script is registered: a correct rejection sends zero HTTP.
  raised = nil
  begin
    changed_ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
  rescue Aiconshell::Oauth::BindingMismatch => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("binding_mismatch")
  expect(ctx[:transport].requests.size).to eq(before_count)
  kept = OauthConnection.find_by(provider: "atlassian")
  expect(kept.state).to eq("connected")
  ctx[:transport].assert_consumed!
end

test("client and tenant changes since connect are rejected before any refresh HTTP") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env
  ctx = OauthTestSupport.services(env: base_env)
  OauthTestSupport.connect(ctx, "microsoft")
  expire_connection_for_refresh!("microsoft")
  before_count = ctx[:transport].requests.size
  expect(before_count).to eq(2)

  changed = base_env.merge("OAUTH_MICROSOFT_TENANT_ID" => "other-tenant")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  # No refresh script is registered: the old refresh token must never be
  # sent externally under the new tenant. The typed binding error (not a
  # fixture ExpectationError) proves the app rejected before HTTP.
  raised = nil
  begin
    changed_ctx[:creds].access_token(ctx[:creds].binding_for("microsoft").to_h)
  rescue Aiconshell::Oauth::BindingMismatch => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("binding_mismatch")
  expect(ctx[:transport].requests.size).to eq(before_count)
  kept = OauthConnection.find_by(provider: "microsoft")
  expect(kept.state).to eq("connected")
  expect(ctx[:store].decrypt(kept.encrypted_access_token) == "at-evil").to eq(false)
  expect(kept.refresh_lease_token.nil?).to eq(true)
  ctx[:transport].assert_consumed!
end

test("held leases reject without HTTP") do |db:|
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
  rescue Aiconshell::Oauth::RefreshBusy => e
    raised = e
  end
  # CredentialProvider passes RefreshBusy through unwrapped.
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("refresh_in_progress")
  expect(ctx[:transport].requests.size).to eq(3) # connect used 3; busy adds none
  ctx[:transport].assert_consumed!
end

test("expired leases clear on the next refresh") do |db:|
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
  reloaded = OauthConnection.find_by(provider: "atlassian")
  expect(reloaded.refresh_lease_token.nil?).to eq(true)
  ctx[:transport].assert_consumed!
end

test("a refresh lease orphaned by disconnect never resurrects through the public port") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  expire_connection_for_refresh!("atlassian")
  stale_binding = ctx[:creds].binding_for("atlassian").to_h
  claimed_row = OauthConnection.find_by(provider: "atlassian")
  claimed_row.update!(
    refresh_lease_token: "lease-doomed",
    refresh_lease_expires_at: 5.minutes.from_now,
    refresh_lease_generation: claimed_row.generation
  )
  before_count = ctx[:transport].requests.size
  ctx[:auth].disconnect(provider: "atlassian")
  # No refresh script is registered: the orphaned lease must die through
  # the real binding/generation fence before any HTTP.
  raised = nil
  begin
    ctx[:creds].access_token(stale_binding)
  rescue Aiconshell::Oauth::BindingMismatch, Aiconshell::Oauth::ProviderError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
  expect(ctx[:transport].requests.size).to eq(before_count)
  ctx[:transport].assert_consumed!
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
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("invalid_grant")
  expect(OauthConnection.find_by(provider: "atlassian").state).to eq("needs_reauth")
  ctx[:transport].assert_consumed!
end

test("concurrent refreshes from separate PG connections serialize on the lease") do
  # Real claim contention: no wrapping db transaction so two threads use
  # independent PG connections on committed rows, with an explicit barrier
  # and finite timeouts. No private-method substitution.
  OauthConnection.where(provider: "atlassian").delete_all
  OauthAuthAttempt.where(provider: "atlassian").delete_all
  inner = BoundaryFixtures::HttpTransport.new
  base_env = OauthTestSupport.test_env
  store = OauthTestSupport.secret_store
  setup_sink = WorkflowFakes::FakeEventSink.new
  setup_ctx = OauthTestSupport.services(env: base_env, transport: inner, store: store, sink: setup_sink)
  OauthTestSupport.connect(setup_ctx, "atlassian")
  OauthConnection.find_by!(provider: "atlassian").update!(token_expires_at: 1.minute.ago)
  binding_h = Oauth::CredentialProvider.new(env: base_env, transport: inner, clock: Time,
                                            secret_store: store,
                                            event_sink: WorkflowFakes::FakeEventSink.new).binding_for("atlassian").to_h
  inner.expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: {
    "access_token" => "at-winner", "refresh_token" => "rt-winner",
    "expires_in" => 3600, "scope" => OauthTestSupport::ATLASSIAN_SCOPES, "token_type" => "Bearer"
  })

  entered = Queue.new
  release = Queue.new
  blocking = BlockingRefreshTransport.new(inner, entered, release)
  winner_result = Queue.new
  loser_result = Queue.new
  winner_pid = Queue.new
  loser_pid = Queue.new

  winner = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      begin
        winner_pid << connection.raw_connection.backend_pid
        creds = Oauth::CredentialProvider.new(env: base_env, transport: blocking, clock: Time,
                                              secret_store: store,
                                              event_sink: WorkflowFakes::FakeEventSink.new)
        winner_result << { ok: true, token: creds.access_token(binding_h) }
      rescue StandardError => e
        # Narrow check happens on the main thread; never swallow the
        # fixture ExpectationError as a valid rejection here.
        winner_result << { ok: false, error: e }
      end
    end
  end
  Timeout.timeout(15) { entered.pop }
  loser = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      begin
        loser_pid << connection.raw_connection.backend_pid
        creds = Oauth::CredentialProvider.new(env: base_env, transport: inner, clock: Time,
                                              secret_store: store,
                                              event_sink: WorkflowFakes::FakeEventSink.new)
        loser_result << { ok: true, token: creds.access_token(binding_h) }
      rescue Aiconshell::Oauth::RefreshBusy, Aiconshell::Oauth::BindingMismatch,
             Aiconshell::Oauth::ProviderError => e
        loser_result << { ok: false, error: e }
      end
    end
  end
  # The loser must finish while the winner still holds the lease inside the
  # network phase; only then may the winner commit.
  loser_outcome = Timeout.timeout(15) { loser_result.pop }
  release << true
  winner_outcome = Timeout.timeout(15) { winner_result.pop }
  Timeout.timeout(15) { winner.join(15) || raise("winner thread stuck") }
  Timeout.timeout(15) { loser.join(15) || raise("loser thread stuck") }
  expect(Timeout.timeout(15) { winner_pid.pop } == Timeout.timeout(15) { loser_pid.pop }).to eq(false)
  expect(winner_outcome[:ok]).to eq(true)
  expect(winner_outcome[:token]).to eq("at-winner")
  expect(loser_outcome[:ok]).to eq(false)
  expect(%w[refresh_in_progress binding_mismatch].include?(loser_outcome[:error].code)).to eq(true)
  # Setup connect used 1 token POST; the winner adds exactly one more.
  expect(inner.requests_to("https://auth.atlassian.com/oauth/token", method: :POST).size).to eq(2)
  inner.assert_consumed!
ensure
  begin
    release << true
  rescue StandardError
    nil
  end
  winner&.kill if defined?(winner) && winner&.alive?
  loser&.kill if defined?(loser) && loser&.alive?
  OauthConnection.where(provider: "atlassian").delete_all
  OauthAuthAttempt.where(provider: "atlassian").delete_all
end
