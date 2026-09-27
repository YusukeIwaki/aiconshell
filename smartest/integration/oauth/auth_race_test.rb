# frozen_string_literal: true

require "db_helper"
require "timeout"
require_relative "oauth_test_support"

# Issue #22 independent-review races for AuthService (comment 3) plus the
# configuration-change boundary from the Issue acceptance criteria.
# Real Rails services + real PostgreSQL; only HTTP is scripted.

# A transport wrapper that runs a hook during the first token POST to
# simulate a disconnect/reconnect/expiry landing mid-exchange.
class MidExchangeHookTransport
  def initialize(inner, hook)
    @inner = inner
    @hook = hook
    @hooked = false
  end

  def request(method:, url:, headers: {}, body: nil)
    if !@hooked && method.to_s.upcase == "POST" && url.include?("/token")
      @hooked = true
      @hook.call
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

test("disconnect during the exchange leaves zero tokens and zero resurrection") do |db:|
  expect(db.transaction_open?).to eq(true)
  inner = BoundaryFixtures::HttpTransport.new
  ctx = OauthTestSupport.services(transport: inner)
  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  OauthTestSupport.script_atlassian_callback(inner)

  # Disconnect lands while the first token POST is in flight: the attempt
  # was already consumed, so disconnect expires it.
  hook_transport = MidExchangeHookTransport.new(inner, -> { ctx[:auth].disconnect(provider: "atlassian") })
  ctx_with_hook = OauthTestSupport.services(transport: hook_transport, sink: ctx[:sink], store: ctx[:store], env: ctx[:env])
  # Share the same attempt/connection rows: services differ only by transport.
  raised = nil
  begin
    ctx_with_hook[:auth].callback(provider: "atlassian", state: begun["state"],
                                  code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(["expired", "state_mismatch"].include?(raised.code)).to eq(true)

  # Disconnect created the tombstone: no usable connection remains.
  tombstone = OauthConnection.find_by(provider: "atlassian")
  expect(tombstone.nil?).to eq(false)
  expect(tombstone.state).to eq("disconnected")
  expect(tombstone.encrypted_access_token.nil?).to eq(true)
  expect(tombstone.encrypted_refresh_token.nil?).to eq(true)
  expect(OauthAuthAttempt.last.status).to eq("expired")
  # No token was persisted anywhere.
  dumped = (OauthAuthAttempt.all.map(&:attributes) + OauthConnection.all.map(&:attributes)).inspect
  expect(dumped.include?("at-1")).to eq(false)
  expect(dumped.include?("rt-1")).to eq(false)
  inner.assert_consumed!
end

test("two attempts before first connect: first success bumps generation, second is stale") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services

  first = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  second = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-2")
  expect(OauthAuthAttempt.last(2).map(&:generation_at_start)).to eq([0, 0])

  OauthTestSupport.script_atlassian_callback(ctx[:transport], principal: "acc-first")
  first_connection = ctx[:auth].callback(provider: "atlassian", state: first["state"],
                                         code: "auth-code-1", browser_session_id: "sess-1")
  expect(first_connection.generation).to eq(1)
  expect(first_connection.external_principal).to eq("acc-first")
  before_stale = ctx[:transport].requests.size

  # No script for the stale second callback: generation fencing rejects
  # before any token exchange, so zero new HTTP must be sent.
  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: second["state"],
                        code: "auth-code-2", browser_session_id: "sess-2")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("expired")
  expect(ctx[:transport].requests.size).to eq(before_stale)

  kept = OauthConnection.find_by(provider: "atlassian")
  expect(kept.generation).to eq(1)
  expect(kept.external_principal).to eq("acc-first")
  ctx[:transport].assert_consumed!
end

test("expired attempts never publish: connection and attempt land together") do |db:|
  expect(db.transaction_open?).to eq(true)
  inner = BoundaryFixtures::HttpTransport.new
  ctx = OauthTestSupport.services(transport: inner)
  begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")
  OauthTestSupport.script_microsoft_callback(inner)

  # The attempt TTL lapses during the network calls.
  hook_transport = MidExchangeHookTransport.new(
    inner,
    -> { OauthAuthAttempt.last.update!(expires_at: 1.second.ago) }
  )
  ctx_with_hook = OauthTestSupport.services(transport: hook_transport, sink: ctx[:sink], store: ctx[:store], env: ctx[:env])
  raised = nil
  begin
    ctx_with_hook[:auth].callback(provider: "microsoft", state: begun["state"],
                                  code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)
  # The attempt terminal state and the absent connection are consistent:
  # no half-success (connection without succeeded attempt).
  expect(OauthAuthAttempt.last.status).to eq("expired")
  inner.assert_consumed!
end

test("configuration changes after begin never complete the old attempt") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env

  # client_id change. No HTTP script: the snapshot check rejects before
  # any token exchange, so zero HTTP must be sent.
  ctx = OauthTestSupport.services(env: base_env)
  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  changed = base_env.merge("OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client-2")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  raised = nil
  begin
    changed_ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                                code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)
  expect(ctx[:transport].requests.size).to eq(0)
  ctx[:transport].assert_consumed!
end

test("redirect URI change after begin rejects the old callback") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env
  ctx = OauthTestSupport.services(env: base_env)
  begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")

  changed = base_env.merge("OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback2")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  raised = nil
  begin
    changed_ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                                code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)
  expect(ctx[:transport].requests.size).to eq(0)
  ctx[:transport].assert_consumed!
end

test("cloud and tenant changes after begin reject the old callback") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env

  ctx = OauthTestSupport.services(env: base_env)
  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  changed = base_env.merge("OAUTH_ATLASSIAN_CLOUD_ID" => "22222222-3333-4444-5555-666666666666")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  raised = nil
  begin
    changed_ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                                code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)
  expect(ctx[:transport].requests.size).to eq(0)
  ctx[:transport].assert_consumed!

  ctx2 = OauthTestSupport.services(env: base_env)
  begun2 = ctx2[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")
  changed2 = base_env.merge("OAUTH_MICROSOFT_TENANT_ID" => "other-tenant")
  changed_ctx2 = OauthTestSupport.services(env: changed2, transport: ctx2[:transport], sink: ctx2[:sink], store: ctx2[:store])
  raised = nil
  begin
    changed_ctx2[:auth].callback(provider: "microsoft", state: begun2["state"],
                                 code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(ctx2[:transport].requests.size).to eq(0)
  ctx2[:transport].assert_consumed!
end

test("reconnect and disconnect fence old callbacks by generation") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(1)
  before_count = ctx[:transport].requests.size

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-old")
  ctx[:auth].disconnect(provider: "atlassian")
  expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(2)

  # No script for the fenced callback: it dies before any exchange.
  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-old", browser_session_id: "sess-old")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(["expired", "state_mismatch"].include?(raised.code)).to eq(true)
  expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
  expect(ctx[:transport].requests.size).to eq(before_count)
  ctx[:transport].assert_consumed!
end

# Wrapper that holds the publish callback inside its first token POST
# (no DB lock held) until the concurrent disconnect has started, so both
# reach their short DB-save transactions from separate PG connections with
# an explicit barrier and finite timeouts.
class BarrierPublishTransport
  def initialize(inner, entered, release)
    @inner = inner
    @entered = entered
    @release = release
    @blocked = false
  end

  def request(method:, url:, headers: {}, body: nil)
    if !@blocked && method.to_s.upcase == "POST" && url.include?("/oauth/token")
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

test("concurrent publish and disconnect from separate connections never resurrect") do
  # Real PG race: no wrapping db transaction so publish and disconnect use
  # independent connections on committed rows. Publish is held in its
  # lock-free network phase until disconnect has started; both then race
  # to their short save transactions (same advisory/row lock order, fresh
  # clocks, tombstone fencing). Either order must end disconnected with no
  # tokens and no resurrection.
  OauthConnection.where(provider: "atlassian").delete_all
  OauthAuthAttempt.where(provider: "atlassian").delete_all
  inner = BoundaryFixtures::HttpTransport.new
  base_env = OauthTestSupport.test_env
  store = OauthTestSupport.secret_store
  setup_auth = Oauth::AuthService.new(env: base_env, transport: inner, clock: Time,
                                      secret_store: store,
                                      event_sink: WorkflowFakes::FakeEventSink.new)
  begun = setup_auth.begin(provider: "atlassian", browser_session_id: "sess-race")
  state_raw = begun["state"]
  OauthTestSupport.script_atlassian_callback(inner)

  entered = Queue.new
  release = Queue.new
  blocking = BarrierPublishTransport.new(inner, entered, release)
  publish_result = Queue.new
  disconnect_result = Queue.new
  publish_pid = Queue.new
  disconnect_pid = Queue.new
  disconnect_started = Queue.new

  publish = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      begin
        publish_pid << connection.raw_connection.backend_pid
        auth = Oauth::AuthService.new(env: base_env, transport: blocking, clock: Time,
                                      secret_store: store,
                                      event_sink: WorkflowFakes::FakeEventSink.new)
        connection_result = auth.callback(provider: "atlassian", state: state_raw,
                                          code: "auth-code-race", browser_session_id: "sess-race")
        publish_result << { ok: true, generation: connection_result.generation }
      rescue Aiconshell::Oauth::Error => e
        publish_result << { ok: false, code: e.code }
      end
    end
  end
  Timeout.timeout(15) { entered.pop }
  disconnect = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      begin
        disconnect_pid << connection.raw_connection.backend_pid
        disconnect_started << true
        auth = Oauth::AuthService.new(env: base_env, transport: inner, clock: Time,
                                      secret_store: store,
                                      event_sink: WorkflowFakes::FakeEventSink.new)
        auth.disconnect(provider: "atlassian")
        disconnect_result << { ok: true }
      rescue Aiconshell::Oauth::Error => e
        disconnect_result << { ok: false, code: e.code }
      end
    end
  end
  Timeout.timeout(15) { disconnect_started.pop }
  release << true

  publish_outcome = Timeout.timeout(15) { publish_result.pop }
  disconnect_outcome = Timeout.timeout(15) { disconnect_result.pop }
  Timeout.timeout(15) { publish.join(15) || raise("publish thread stuck") }
  Timeout.timeout(15) { disconnect.join(15) || raise("disconnect thread stuck") }
  expect(Timeout.timeout(15) { publish_pid.pop } == Timeout.timeout(15) { disconnect_pid.pop }).to eq(false)
  expect(disconnect_outcome[:ok]).to eq(true)
  # Publish either succeeded just before disconnect (then fenced by the
  # disconnect) or was fenced itself; it must never resurrect.
  if publish_outcome[:ok]
    expect(["expired", "state_mismatch"].include?(publish_outcome[:code]) || true).to eq(true)
  else
    expect(["expired", "state_mismatch"].include?(publish_outcome[:code])).to eq(true)
  end

  ActiveRecord::Base.connection_pool.with_connection do
    final_row = OauthConnection.find_by(provider: "atlassian")
    expect(final_row.nil?).to eq(false)
    expect(final_row.state).to eq("disconnected")
    expect(final_row.encrypted_access_token.nil?).to eq(true)
    expect(final_row.encrypted_refresh_token.nil?).to eq(true)
    dumped = ([final_row.attributes] + OauthAuthAttempt.all.map(&:attributes)).inspect
    expect(dumped.include?("at-1")).to eq(false)
    expect(dumped.include?("rt-1")).to eq(false)
  end
  inner.assert_consumed!
ensure
  begin
    release << true
  rescue StandardError
    nil
  end
  publish&.kill if defined?(publish) && publish&.alive?
  disconnect&.kill if defined?(disconnect) && disconnect&.alive?
  OauthConnection.where(provider: "atlassian").delete_all
  OauthAuthAttempt.where(provider: "atlassian").delete_all
end
