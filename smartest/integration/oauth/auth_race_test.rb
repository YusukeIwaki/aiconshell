# frozen_string_literal: true

require "db_helper"
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

  expect(OauthConnection.count).to eq(0)
  expect(OauthAuthAttempt.last.status).to eq("expired")
  # No token was persisted anywhere.
  dumped = (OauthAuthAttempt.all.map(&:attributes) + OauthConnection.all.map(&:attributes)).inspect
  expect(dumped.include?("at-1")).to eq(false)
  expect(dumped.include?("rt-1")).to eq(false)
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

  OauthTestSupport.script_atlassian_callback(ctx[:transport], principal: "acc-second")
  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: second["state"],
                        code: "auth-code-2", browser_session_id: "sess-2")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
  expect(raised.code).to eq("expired")

  kept = OauthConnection.find_by(provider: "atlassian")
  expect(kept.generation).to eq(1)
  expect(kept.external_principal).to eq("acc-first")
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
end

test("configuration changes after begin never complete the old attempt") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env

  # client_id change.
  ctx = OauthTestSupport.services(env: base_env)
  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  changed = base_env.merge("OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client-2")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  OauthTestSupport.script_atlassian_callback(changed_ctx[:transport])
  raised = nil
  begin
    changed_ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                                code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)
end

test("redirect URI change after begin rejects the old callback") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env
  ctx = OauthTestSupport.services(env: base_env)
  begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")

  changed = base_env.merge("OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback2")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  OauthTestSupport.script_microsoft_callback(changed_ctx[:transport])
  raised = nil
  begin
    changed_ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                                code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)
end

test("cloud and tenant changes after begin reject the old callback") do |db:|
  expect(db.transaction_open?).to eq(true)
  base_env = OauthTestSupport.test_env

  ctx = OauthTestSupport.services(env: base_env)
  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-1")
  changed = base_env.merge("OAUTH_ATLASSIAN_CLOUD_ID" => "22222222-3333-4444-5555-666666666666")
  changed_ctx = OauthTestSupport.services(env: changed, transport: ctx[:transport], sink: ctx[:sink], store: ctx[:store])
  OauthTestSupport.script_atlassian_callback(changed_ctx[:transport])
  raised = nil
  begin
    changed_ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                                code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
  expect(OauthConnection.count).to eq(0)

  ctx2 = OauthTestSupport.services(env: base_env)
  begun2 = ctx2[:auth].begin(provider: "microsoft", browser_session_id: "sess-1")
  changed2 = base_env.merge("OAUTH_MICROSOFT_TENANT_ID" => "other-tenant")
  changed_ctx2 = OauthTestSupport.services(env: changed2, transport: ctx2[:transport], sink: ctx2[:sink], store: ctx2[:store])
  OauthTestSupport.script_microsoft_callback(changed_ctx2[:transport])
  raised = nil
  begin
    changed_ctx2[:auth].callback(provider: "microsoft", state: begun2["state"],
                                 code: "auth-code-1", browser_session_id: "sess-1")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(raised.code).to eq("expired")
end

test("reconnect and disconnect fence old callbacks by generation") do |db:|
  expect(db.transaction_open?).to eq(true)
  ctx = OauthTestSupport.services
  OauthTestSupport.connect(ctx, "atlassian")
  expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(1)

  begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "sess-old")
  ctx[:auth].disconnect(provider: "atlassian")
  expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(2)

  raised = nil
  begin
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-old", browser_session_id: "sess-old")
  rescue Aiconshell::Oauth::Error => e
    raised = e
  end
  expect(["expired", "state_mismatch"].include?(raised.code)).to eq(true)
  expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
end
