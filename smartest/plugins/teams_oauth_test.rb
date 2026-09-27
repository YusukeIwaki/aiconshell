# frozen_string_literal: true

require "test_helper"
require "json"
require "time"
require "uri"
require_relative "../../lib/aiconshell/plugins"
require_relative "../../lib/aiconshell/plugins/teams_oauth"
require_relative "../../lib/aiconshell/oauth/errors"
require_relative "../support/boundary_fixtures"

# Standalone suite for the teams_oauth adapter (issue #25). Uses the real
# Registry with the adapter explicitly required and registered (the default
# registry is untouched; wiring is a later issue). Every HTTP expectation is
# finite and every test ends with assert_consumed!.
module TeamsOauthCases
  GRAPH_BASE = "https://graph.microsoft.com/v1.0"
  TOKEN = "oauth-test-token"
  BINDING = {
    "connection_id" => 7,
    "generation" => 3,
    "provider" => "microsoft",
    "principal" => "user-1",
    "tenant" => "tenant-1",
    "cloud" => nil
  }.freeze
  OAUTH_ENV = {
    "OAUTH_MICROSOFT_CLIENT_ID" => "ms-client",
    "OAUTH_MICROSOFT_CLIENT_SECRET" => "ms-secret",
    "OAUTH_MICROSOFT_TENANT_ID" => "tenant-1",
    "OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback"
  }.freeze
  READ_SCOPES = %w[teams_oauth:read].freeze
  WRITE_SCOPES = %w[teams_oauth:write].freeze

  class FixedClock
    def initialize(now)
      @now = now
    end

    def now
      @now
    end
  end

  # Same binding_for/access_token ports as the Rails CredentialProvider.
  # Accepts Binding objects or hashes; compares by secret-free to_h so the
  # adapter may pass the normalized Binding like the Jira lane.
  class FakeOauthProvider
    attr_reader :received

    def initialize(expected_binding, token: TOKEN, error: nil)
      @expected_binding = expected_binding
      @token = token
      @error = error
      @received = []
    end

    def access_token(binding)
      @received << binding
      raise @error if @error

      actual = binding.respond_to?(:to_h) ? binding.to_h : binding
      expected = @expected_binding.respond_to?(:to_h) ? @expected_binding.to_h : @expected_binding
      unless actual == expected
        raise Aiconshell::Oauth::BindingMismatch.new
      end

      @token
    end

    def received_hashes
      @received.map { |binding| binding.respond_to?(:to_h) ? binding.to_h : binding }
    end
  end

  # Lenient provider that returns a token for any binding. Used to prove
  # that incomplete bindings are rejected before any Graph I/O.
  class LenientOauthProvider
    attr_reader :calls

    def initialize(token: TOKEN)
      @token = token
      @calls = 0
    end

    def access_token(_binding)
      @calls += 1
      @token
    end
  end

  class << self
    def registry_for(transport, provider, env: OAUTH_ENV)
      registry = Aiconshell::Plugins::Registry.new(
        env: env, transport: transport,
        clock: FixedClock.new(Time.utc(2026, 9, 26, 12, 0, 0))
      )
      if provider.nil?
        registry.register(Aiconshell::Plugins::TeamsOauth.new)
      else
        registry.register(Aiconshell::Plugins::TeamsOauth.new(oauth_credential_provider: provider))
      end
      registry
    end

    def context_for(scopes, provider, binding: BINDING)
      ctx = { "scopes" => scopes, "oauth_binding" => binding }
      ctx["oauth_credential_provider"] = provider unless provider.nil?
      ctx
    end

    def graph_message(id, created:, modified:, from: { "user" => { "id" => "u1" } }, body: "hello")
      {
        "id" => id, "createdDateTime" => created, "lastModifiedDateTime" => modified,
        "etag" => "etag-#{id}", "subject" => nil,
        "from" => from,
        "body" => { "content" => body, "contentType" => "text" },
        "webUrl" => "https://teams.test/m/#{id}"
      }
    end

    def channel_scope
      "team/team-1/channel/19:chan@thread.tacv2"
    end

    def channel_first_url
      "#{GRAPH_BASE}/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$top=50"
    end
  end
end

def oauth_transport
  BoundaryFixtures::HttpTransport.new
end

def oauth_provider(binding = TeamsOauthCases::BINDING, **kwargs)
  TeamsOauthCases::FakeOauthProvider.new(binding, **kwargs)
end

def oauth_registry(transport, provider, env: TeamsOauthCases::OAUTH_ENV)
  TeamsOauthCases::registry_for(transport, provider, env: env)
end

def oauth_ctx(scopes, provider, binding: TeamsOauthCases::BINDING)
  TeamsOauthCases::context_for(scopes, provider, binding: binding)
end

test("teams_oauth channel poll reads messages plus all replies with paging") do
  transport = oauth_transport
  provider = oauth_provider
  first = TeamsOauthCases.channel_first_url
  nxt = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$skiptoken=abc"
  transport.expect_json(:GET, first, body: {
                          "value" => [TeamsOauthCases.graph_message("m1",
                            created: "2026-09-26T11:10:00Z", modified: "2026-09-26T11:10:00Z")],
                          "@odata.nextLink" => nxt
                        })
  transport.expect_json(:GET, nxt, body: {
                          "value" => [TeamsOauthCases.graph_message("m2",
                            created: "2026-09-26T11:20:00Z", modified: "2026-09-26T11:25:00Z",
                            from: { "application" => { "id" => "app1" } })]
                        })
  transport.expect_json(:GET, %r{/messages/m1/replies}, body: {
                          "value" => [TeamsOauthCases.graph_message("r1",
                            created: "2026-09-26T11:30:00Z", modified: "2026-09-26T11:30:00Z",
                            body: "reply")]
                        })
  transport.expect_json(:GET, %r{/messages/m2/replies}, body: { "value" => [] })

  registry = oauth_registry(transport, provider)
  out = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                        input: { "scope" => TeamsOauthCases.channel_scope,
                                 "cursor" => { "since" => "2026-09-26T11:00:00Z" } },
                        context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))

  ids = out["events"].map { |e| e["event_id"] }
  expect(ids).to eq(["teams_oauth:message:team-1/19%3Achan%40thread.tacv2/m1",
                     "teams_oauth:message:team-1/19%3Achan%40thread.tacv2/m2",
                     "teams_oauth:reply:team-1/19%3Achan%40thread.tacv2/m1/r1"])
  expect(out["events"][0]["event_type"]).to eq("teams_oauth.message")
  expect(out["events"][2]["event_type"]).to eq("teams_oauth.reply")
  expect(out["events"][1]["actor_type"]).to eq("bot")
  expect(out["events"][0]["actor_type"]).to eq("human")
  expect(out["events"][2]["resource_id"]).to eq("message:team-1/19:chan@thread.tacv2/m1")
  expect(out["events"][2]["payload"]["reply_to_id"]).to eq("m1")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T11:30:00Z" })

  graph_calls = transport.requests.select { |r| r[:url].start_with?("https://graph.microsoft.com") }
  expect(graph_calls.size).to eq(4)
  expected_auth = "Bearer #{TeamsOauthCases::TOKEN}"
  expect(graph_calls.map { |r| r[:headers]["Authorization"] }.uniq).to eq([expected_auth])
  expect(graph_calls.any? { |r| r[:url].include?("$filter") }).to eq(false)
  # The trusted binding is resolved as-is; the adapter never re-selects it.
  expect(provider.received_hashes).to eq([TeamsOauthCases::BINDING])
  transport.assert_consumed!
end

test("teams_oauth chat poll reads every page without fetching replies") do
  transport = oauth_transport
  provider = oauth_provider
  first = "#{TeamsOauthCases::GRAPH_BASE}/chats/chat-1/messages?$top=50"
  nxt = "#{TeamsOauthCases::GRAPH_BASE}/chats/chat-1/messages?$skiptoken=page2"
  transport.expect_json(:GET, first, body: {
                          "value" => [TeamsOauthCases.graph_message("c1",
                            created: "2026-09-26T11:10:00Z", modified: "2026-09-26T11:10:00Z")],
                          "@odata.nextLink" => nxt
                        })
  transport.expect_json(:GET, nxt, body: {
                          "value" => [TeamsOauthCases.graph_message("c2",
                            created: "2026-09-26T11:20:00Z", modified: "2026-09-26T11:20:00Z")]
                        })

  registry = oauth_registry(transport, provider)
  out = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                        input: { "scope" => "chat/chat-1",
                                 "cursor" => { "since" => "2026-09-26T11:00:00Z" } },
                        context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))

  expect(out["events"].map { |e| e["event_id"] })
    .to eq(["teams_oauth:chat_message:chat-1/c1", "teams_oauth:chat_message:chat-1/c2"])
  expect(out["events"].map { |e| e["event_type"] }.uniq).to eq(["teams_oauth.chat_message"])
  expect(out["events"].map { |e| e["resource_id"] }.uniq)
    .to eq(["chat_message:chat-1/c1", "chat_message:chat-1/c2"])
  expect(out["events"][0]["payload"]["chat_id"]).to eq("chat-1")
  expect(out["events"][0]["actor_type"]).to eq("human")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T11:20:00Z" })
  expect(transport.requests_to(%r{/replies}).size).to eq(0)
  transport.assert_consumed!
end

test("teams_oauth channel send posts a text message without spoofing from") do
  transport = oauth_transport
  provider = oauth_provider
  url = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
  transport.expect_json(:POST, url, body: { "id" => "new-1" })

  registry = oauth_registry(transport, provider)
  out = registry.invoke(plugin: "teams_oauth", operation: "send_message",
                        input: { "scope" => "channel:team-1/chan-1", "body" => "hello" },
                        context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))

  expect(out).to eq({ "external_id" => "message:team-1/chan-1/new-1", "url" => nil })
  req = transport.requests_to(url).first
  parsed = JSON.parse(req[:body])
  expect(parsed).to eq({ "body" => { "contentType" => "text", "content" => "hello" } })
  expect(parsed.key?("from")).to eq(false)
  expect(req[:headers]["Authorization"]).to eq("Bearer #{TeamsOauthCases::TOKEN}")
  expect(transport.requests_to(url).size).to eq(1)
  transport.assert_consumed!
end

test("teams_oauth channel reply targets the root replies endpoint") do
  transport = oauth_transport
  provider = oauth_provider
  url = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/root-1/replies"
  transport.expect_json(:POST, url, body: { "id" => "reply-9" })

  registry = oauth_registry(transport, provider)
  out = registry.invoke(plugin: "teams_oauth", operation: "reply",
                        input: { "resource_id" => "message:team-1/chan-1/root-1", "body" => "ack" },
                        context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))

  expect(out).to eq({ "external_id" => "message:team-1/chan-1/root-1/reply-9", "url" => nil })
  req = transport.requests_to(url).first
  expect(JSON.parse(req[:body])).to eq({ "body" => { "contentType" => "text", "content" => "ack" } })
  expect(transport.requests_to(url).size).to eq(1)
  transport.assert_consumed!
end

test("teams_oauth chat send and chat reply both post a new chat message") do
  transport = oauth_transport
  provider = oauth_provider
  url = "#{TeamsOauthCases::GRAPH_BASE}/chats/chat-1/messages"
  transport.expect_json(:POST, url, body: { "id" => "cm-1" })
  transport.expect_json(:POST, url, body: { "id" => "cm-2" })

  registry = oauth_registry(transport, provider)
  sent = registry.invoke(plugin: "teams_oauth", operation: "send_message",
                         input: { "scope" => "chat:chat-1", "body" => "hello" },
                         context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))
  # Chats expose no thread-reply endpoint: a reply is a new message to the
  # same chat (never a fabricated reply API).
  replied = registry.invoke(plugin: "teams_oauth", operation: "reply",
                            input: { "resource_id" => "chat_message:chat-1/cm-1", "body" => "ack" },
                            context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))

  expect(sent).to eq({ "external_id" => "chat_message:chat-1/cm-1", "url" => nil })
  expect(replied).to eq({ "external_id" => "chat_message:chat-1/cm-2", "url" => nil })
  expect(transport.requests_to(url).size).to eq(2)
  expect(transport.requests_to(%r{/replies}).size).to eq(0)
  transport.assert_consumed!
end

test("teams_oauth keeps a new reply on an old root within overlap") do
  transport = oauth_transport
  provider = oauth_provider
  transport.expect_json(:GET, %r{/messages\?}, body: {
                          "value" => [TeamsOauthCases.graph_message("old-root",
                            created: "2026-01-01T12:00:00Z", modified: "2026-01-01T12:00:00Z")]
                        })
  transport.expect_json(:GET, %r{/messages/old-root/replies}, body: {
                          "value" => [TeamsOauthCases.graph_message("recent",
                            created: "2026-09-26T05:01:00-07:00", modified: "2026-09-26T05:01:00-07:00")]
                        })

  registry = oauth_registry(transport, provider)
  out = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                        input: { "scope" => TeamsOauthCases.channel_scope,
                                 "cursor" => { "since" => "2026-09-26T12:00:00Z" } },
                        context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))

  expect(out["events"].map { |e| e["payload"]["message_id"] }).to eq(["recent"])
  expect(out["events"].first["resource_id"]).to eq("message:team-1/19:chan@thread.tacv2/old-root")
  expect(out["events"].first["occurred_at"]).to eq("2026-09-26T12:01:00Z")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:01:00Z" })
  transport.assert_consumed!
end

test("teams_oauth chat edits return the same event with a new fingerprint") do
  transport = oauth_transport
  provider = oauth_provider
  url = "#{TeamsOauthCases::GRAPH_BASE}/chats/chat-1/messages?$top=50"
  transport.expect_json(:GET, url, body: {
                          "value" => [TeamsOauthCases.graph_message("c1",
                            created: "2026-09-26T11:00:00Z", modified: "2026-09-26T12:00:00Z",
                            body: "version 1")]
                        })
  transport.expect_json(:GET, url, body: {
                          "value" => [TeamsOauthCases.graph_message("c1",
                            created: "2026-09-26T11:00:00Z", modified: "2026-09-26T12:00:00Z",
                            body: "version 2")]
                        })

  registry = oauth_registry(transport, provider)
  ctx = oauth_ctx(TeamsOauthCases::READ_SCOPES, provider)
  before = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                           input: { "scope" => "chat/chat-1" }, context: ctx)
  after = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                          input: { "scope" => "chat/chat-1", "cursor" => before["cursor"] },
                          context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))

  expect(after["events"].first["event_id"]).to eq(before["events"].first["event_id"])
  expect(after["events"].first["fingerprint"]).not_to eq(before["events"].first["fingerprint"])
  transport.assert_consumed!
end

test("teams_oauth raises incomplete poll at the page cap without a cursor") do
  transport = oauth_transport
  provider = oauth_provider
  base = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
  previous = "#{base}?$top=50"
  25.times do |page|
    nxt = "#{base}?$skiptoken=#{page + 1}"
    transport.expect_json(:GET, previous, body: { "value" => [], "@odata.nextLink" => nxt })
    previous = nxt
  end

  registry = oauth_registry(transport, provider)
  cursor = { "since" => "2026-09-26T11:00:00Z" }
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => "team/team-1/channel/chan-1", "cursor" => cursor },
                    context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
    raise "expected incomplete poll"
  rescue Aiconshell::Plugins::IncompletePoll => e
    expect(e.reason).to match(/page limit/)
  end
  expect(cursor).to eq({ "since" => "2026-09-26T11:00:00Z" })
  expect(transport.requests.size).to eq(25)
  transport.assert_consumed!
end

test("teams_oauth rejects pagination cycles without returning partial data") do
  transport = oauth_transport
  provider = oauth_provider
  first = TeamsOauthCases.channel_first_url
  transport.expect_json(:GET, first, body: { "value" => [], "@odata.nextLink" => first })

  registry = oauth_registry(transport, provider)
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
    raise "expected incomplete poll"
  rescue Aiconshell::Plugins::IncompletePoll => e
    expect(e.reason).to match(/did not advance/)
  end
  expect(transport.requests_to(first).size).to eq(1)
  transport.assert_consumed!
end

test("teams_oauth refuses cross-host next links before any follow-up") do
  transport = oauth_transport
  provider = oauth_provider
  transport.expect_json(:GET, TeamsOauthCases.channel_first_url, body: {
                          "value" => [], "@odata.nextLink" => "https://evil.test/next"
                        })

  registry = oauth_registry(transport, provider)
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
    raise "expected host rejection"
  rescue Aiconshell::Plugins::HostRejected => e
    expect(e.host).to eq("evil.test")
  end
  expect(transport.requests_to(%r{evil\.test}).size).to eq(0)
  transport.assert_consumed!
end

test("teams_oauth refuses same-host next links outside the polled collection") do
  transport = oauth_transport
  provider = oauth_provider
  other = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/other-chan/messages?$skiptoken=x"
  transport.expect_json(:GET, TeamsOauthCases.channel_first_url, body: {
                          "value" => [], "@odata.nextLink" => other
                        })

  registry = oauth_registry(transport, provider)
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
    raise "expected cross-collection rejection"
  rescue Aiconshell::Plugins::OutputInvalid => e
    expect(e.details.first).to match(/outside the polled collection/)
  end
  expect(transport.requests_to(%r{other-chan}).size).to eq(0)

  transport2 = oauth_transport
  provider2 = oauth_provider
  frag = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$skiptoken=y#frag"
  transport2.expect_json(:GET, TeamsOauthCases.channel_first_url, body: {
                           "value" => [], "@odata.nextLink" => frag
                         })
  registry2 = oauth_registry(transport2, provider2)
  begin
    registry2.invoke(plugin: "teams_oauth", operation: "latest_events",
                     input: { "scope" => TeamsOauthCases.channel_scope },
                     context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider2))
    raise "expected fragment rejection"
  rescue Aiconshell::Plugins::OutputInvalid => e
    expect(e.details.first).to match(/fragment/)
  end
  transport.assert_consumed!
  transport2.assert_consumed!
end

test("teams_oauth enforces its own read and write scopes") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)

  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: oauth_ctx(%w[teams:read], provider))
    raise "expected permission denial"
  rescue Aiconshell::Plugins::PermissionDenied => e
    expect(e.required_scope).to eq("teams_oauth:read")
  end

  begin
    registry.invoke(plugin: "teams_oauth", operation: "send_message",
                    input: { "scope" => "channel:team-1/chan-1", "body" => "x" },
                    context: oauth_ctx(%w[teams_oauth:read], provider))
    raise "expected permission denial"
  rescue Aiconshell::Plugins::PermissionDenied => e
    expect(e.required_scope).to eq("teams_oauth:write")
  end
  expect(transport.requests).to eq([])
  transport.assert_consumed!
end

test("teams_oauth requires binding and provider before any HTTP") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, nil)

  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: { "scopes" => TeamsOauthCases::READ_SCOPES,
                               "oauth_binding" => TeamsOauthCases::BINDING })
    raise "expected missing provider"
  rescue Aiconshell::Plugins::CredentialsMissing => e
    expect(e.missing).to eq(["oauth_credential_provider"])
  end

  ctx_without_binding = { "scopes" => TeamsOauthCases::READ_SCOPES,
                          "oauth_credential_provider" => provider }
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: ctx_without_binding)
    raise "expected missing binding"
  rescue Aiconshell::Plugins::CredentialsMissing => e
    expect(e.missing).to eq(["oauth_binding"])
  end
  expect(provider.received_hashes).to eq([])
  expect(transport.requests).to eq([])
  transport.assert_consumed!
end

test("teams_oauth rejects replaced bindings and foreign providers without I/O") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)
  stale = TeamsOauthCases::BINDING.merge("generation" => 999)

  begin
    registry.invoke(plugin: "teams_oauth", operation: "send_message",
                    input: { "scope" => "channel:team-1/chan-1", "body" => "x" },
                    context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider, binding: stale))
    raise "expected binding rejection"
  rescue Aiconshell::Oauth::BindingMismatch => e
    expect(e.code).to eq("binding_mismatch")
  end

  atlassian = TeamsOauthCases::BINDING.merge("provider" => "atlassian")
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider, binding: atlassian))
    raise "expected provider rejection"
  rescue Aiconshell::Plugins::CredentialsMissing => e
    expect(e.missing.first).to match(/oauth_binding/)
  end
  expect(transport.requests).to eq([])
  transport.assert_consumed!
end

test("teams_oauth preserves typed OAuth failures without Graph I/O") do
  failures = {
    "timeout" => Aiconshell::Oauth::ProviderError.new("timeout"),
    "rate_limited" => Aiconshell::Oauth::ProviderError.new("rate_limited"),
    "refresh_busy" => Aiconshell::Oauth::RefreshBusy.new,
    "binding_mismatch" => Aiconshell::Oauth::BindingMismatch.new,
    "not_connected" => Aiconshell::Oauth::ProviderError.new("not_connected")
  }
  failures.each do |code, error|
    transport = oauth_transport
    failing = oauth_provider(TeamsOauthCases::BINDING, error: error)
    registry = oauth_registry(transport, failing)
    begin
      registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                      input: { "scope" => TeamsOauthCases.channel_scope },
                      context: oauth_ctx(TeamsOauthCases::READ_SCOPES, failing))
      raise "expected provider failure for #{code}"
    rescue Aiconshell::Oauth::Error => e
      expect(e.code).to eq(error.code)
      expect(e.message).not_to include(TeamsOauthCases::TOKEN)
    end
    expect(transport.requests).to eq([])
    transport.assert_consumed!
  end
end

test("teams_oauth rejects an invalid token with a single call and no replay") do
  transport = oauth_transport
  provider = oauth_provider
  url = TeamsOauthCases.channel_first_url
  transport.expect_json(:GET, url, status: 401, body: { "error" => { "code" => "InvalidAuthenticationToken" } })

  registry = oauth_registry(transport, provider)
  begin
    registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                    input: { "scope" => TeamsOauthCases.channel_scope },
                    context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
    raise "expected HTTP failure"
  rescue Aiconshell::Plugins::HttpError => e
    expect(e.status).to eq(401)
  end
  expect(transport.requests_to(url).size).to eq(1)
  transport.assert_consumed!
end

test("teams_oauth does not replay writes on rate limiting or timeouts") do
  transport = oauth_transport
  provider = oauth_provider
  url = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
  transport.expect_json(:POST, url, status: 429,
                                  headers: { "Retry-After" => "5" }, body: {})

  registry = oauth_registry(transport, provider)
  begin
    registry.invoke(plugin: "teams_oauth", operation: "send_message",
                    input: { "scope" => "channel:team-1/chan-1", "body" => "x" },
                    context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))
    raise "expected rate limiting"
  rescue Aiconshell::Plugins::RateLimited => e
    expect(e.status).to eq(429)
  end
  expect(transport.requests_to(url).size).to eq(1)
  transport.assert_consumed!

  transport2 = oauth_transport
  provider2 = oauth_provider
  chat_url = "#{TeamsOauthCases::GRAPH_BASE}/chats/chat-1/messages"
  timeout = Aiconshell::Plugins::TransportTimeout.new(http_method: "POST", url: chat_url, timeout_kind: "read")
  transport2.expect_error(:POST, chat_url, timeout)
  registry2 = oauth_registry(transport2, provider2)
  begin
    registry2.invoke(plugin: "teams_oauth", operation: "send_message",
                     input: { "scope" => "chat:chat-1", "body" => "x" },
                     context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider2))
    raise "expected timeout"
  rescue Aiconshell::Plugins::TransportTimeout
    nil
  end
  expect(transport2.requests_to(chat_url).size).to eq(1)
  transport2.assert_consumed!
end

test("teams_oauth keeps create_issue unsupported") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)

  begin
    registry.invoke(plugin: "teams_oauth", operation: "create_issue",
                    input: { "scope" => "channel:team-1/chan-1", "title" => "t", "body" => "b" },
                    context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))
    raise "expected unsupported operation"
  rescue Aiconshell::Plugins::UnsupportedOperation
    nil
  end
  expect(transport.requests).to eq([])
  transport.assert_consumed!
end

test("teams_oauth rejects malformed and traversal scopes before I/O") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)
  read_ctx = oauth_ctx(TeamsOauthCases::READ_SCOPES, provider)
  write_ctx = oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider)

  [
    ["latest_events", { "scope" => "team/team-1" }, read_ctx],
    ["latest_events", { "scope" => "team/../channel/chan-1" }, read_ctx],
    ["latest_events", { "scope" => "chat/ch at-1" }, read_ctx],
    ["latest_events", { "scope" => "channel:team-1/chan-1" }, read_ctx],
    ["latest_events", { "scope" => "team/team%2Fevil/channel/chan-1" }, read_ctx],
    ["latest_events", { "scope" => "chat/chat%252Fevil" }, read_ctx],
    ["latest_events", { "scope" => "team/team-1/channel/.." }, read_ctx],
    ["send_message", { "scope" => "message:team-1/chan-1/root-1", "body" => "x" }, write_ctx],
    ["send_message", { "scope" => "chat:../secret", "body" => "x" }, write_ctx],
    ["send_message", { "scope" => "channel:team-1/chan%2F1", "body" => "x" }, write_ctx],
    ["send_message", { "scope" => "chat:chat%25evil", "body" => "x" }, write_ctx]
  ].each do |operation, input, ctx|
    begin
      registry.invoke(plugin: "teams_oauth", operation: operation, input: input, context: ctx)
      raise "expected invalid input for #{input}"
    rescue Aiconshell::Plugins::InputInvalid
      nil
    end
  end

  [
    { "resource_id" => "channel:team-1/chan-1", "body" => "x" },
    { "resource_id" => "message:team-1/chan-1", "body" => "x" },
    { "resource_id" => "chat:chat-1", "body" => "x" },
    { "resource_id" => "chat_message:chat-1/cm-1/extra", "body" => "x" }
  ].each do |input|
    begin
      registry.invoke(plugin: "teams_oauth", operation: "reply", input: input, context: write_ctx)
      raise "expected invalid reply target for #{input}"
    rescue Aiconshell::Plugins::InputInvalid
      nil
    end
  end
  expect(provider.received_hashes).to eq([])
  expect(transport.requests).to eq([])
  transport.assert_consumed!
end

test("teams_oauth rejects invalid cursors and remote timestamps before advancing") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)
  ctx = oauth_ctx(TeamsOauthCases::READ_SCOPES, provider)

  ["2026-02-30T12:00:00Z", "2026-09-26T12:00:00", "not-a-date"].each do |since|
    begin
      registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                      input: { "scope" => "chat/chat-1", "cursor" => { "since" => since } },
                      context: ctx)
      raise "expected invalid cursor"
    rescue Aiconshell::Plugins::InputInvalid => e
      expect(e.details.first).to match(/ISO8601/)
    end
  end
  expect(transport.requests).to eq([])
  expect(provider.received_hashes).to eq([])
  transport.assert_consumed!

  transport2 = oauth_transport
  provider2 = oauth_provider
  transport2.expect_json(:GET, %r{/messages\?}, body: {
                           "value" => [TeamsOauthCases.graph_message("bad",
                             created: "2026-09-26T12:00:00Z", modified: "2026-02-30T12:00:00Z")]
                         })
  registry2 = oauth_registry(transport2, provider2)
  begin
    registry2.invoke(plugin: "teams_oauth", operation: "latest_events",
                     input: { "scope" => "chat/chat-1" },
                     context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider2))
    raise "expected invalid timestamp"
  rescue Aiconshell::Plugins::OutputInvalid => e
    expect(e.details.first).to match(/timestamp/)
  end
  transport2.assert_consumed!
end

test("teams_oauth keeps event ids unique across channel and chat scopes") do
  transport = oauth_transport
  provider = oauth_provider
  transport.expect_json(:GET, %r{/teams/team-9/channels/chan-9/messages}, body: {
                          "value" => [TeamsOauthCases.graph_message("same-id",
                            created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                        })
  transport.expect_json(:GET, %r{/messages/same-id/replies}, body: { "value" => [] })
  transport.expect_json(:GET, %r{/chats/chat-9/messages}, body: {
                          "value" => [TeamsOauthCases.graph_message("same-id",
                            created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                        })

  registry = oauth_registry(transport, provider)
  ctx = oauth_ctx(TeamsOauthCases::READ_SCOPES, provider)
  channel_events = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                                   input: { "scope" => "team/team-9/channel/chan-9" },
                                   context: ctx)["events"]
  chat_events = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                                input: { "scope" => "chat/chat-9" },
                                context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))["events"]

  ids = (channel_events + chat_events).map { |e| e["event_id"] }
  expect(ids.uniq.size).to eq(2)
  expect(channel_events.first["resource_id"]).to eq("message:team-9/chan-9/same-id")
  expect(chat_events.first["resource_id"]).to eq("chat_message:chat-9/same-id")
  transport.assert_consumed!
end

test("teams_oauth writes fail on unexpected Graph shapes and tokens") do
  transport = oauth_transport
  provider = oauth_provider
  url = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
  transport.expect_json(:POST, url, body: { "no_id" => true })

  registry = oauth_registry(transport, provider)
  begin
    registry.invoke(plugin: "teams_oauth", operation: "send_message",
                    input: { "scope" => "channel:team-1/chan-1", "body" => "x" },
                    context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))
    raise "expected output failure"
  rescue Aiconshell::Plugins::OutputInvalid => e
    expect(e.details.first).to match(/message id/)
  end
  transport.assert_consumed!

  transport2 = oauth_transport
  bad_token = oauth_provider(TeamsOauthCases::BINDING, token: 42)
  registry2 = oauth_registry(transport2, bad_token)
  begin
    registry2.invoke(plugin: "teams_oauth", operation: "latest_events",
                     input: { "scope" => "chat/chat-1" },
                     context: oauth_ctx(TeamsOauthCases::READ_SCOPES, bad_token))
    raise "expected token failure"
  rescue Aiconshell::Plugins::OutputInvalid => e
    expect(e.details.first).to match(/token/)
  end
  expect(transport2.requests).to eq([])
  transport2.assert_consumed!
end

test("teams_oauth accepts a constructor-injected provider from context-less callers") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)

  transport.expect_json(:GET, %r{/chats/chat-7/messages}, body: { "value" => [] })
  out = registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                        input: { "scope" => "chat/chat-7" },
                        context: { "oauth_binding" => TeamsOauthCases::BINDING })
  expect(out["events"]).to eq([])
  expect(provider.received_hashes).to eq([TeamsOauthCases::BINDING])
  transport.assert_consumed!
end

test("teams_oauth rejects incomplete bindings before HTTP even with a lenient provider") do
  incomplete = [
    TeamsOauthCases::BINDING.merge("provider" => nil),
    TeamsOauthCases::BINDING.merge("provider" => "atlassian"),
    TeamsOauthCases::BINDING.merge("principal" => ""),
    TeamsOauthCases::BINDING.merge("tenant" => ""),
    TeamsOauthCases::BINDING.merge("tenant" => "common"),
    TeamsOauthCases::BINDING.merge("connection_id" => nil)
  ]
  incomplete.each do |bad|
    transport = oauth_transport
    lenient = TeamsOauthCases::LenientOauthProvider.new
    registry = Aiconshell::Plugins::Registry.new(
      env: TeamsOauthCases::OAUTH_ENV, transport: transport,
      clock: TeamsOauthCases::FixedClock.new(Time.utc(2026, 9, 26, 12, 0, 0))
    )
    registry.register(Aiconshell::Plugins::TeamsOauth.new(oauth_credential_provider: lenient))
    begin
      registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                      input: { "scope" => TeamsOauthCases.channel_scope },
                      context: { "scopes" => TeamsOauthCases::READ_SCOPES, "oauth_binding" => bad })
      raise "expected binding rejection for #{bad.inspect}"
    rescue Aiconshell::Plugins::CredentialsMissing => e
      expect(e.missing.first).to match(/oauth_binding/)
    end
    expect(lenient.calls).to eq(0)
    expect(transport.requests).to eq([])
    transport.assert_consumed!
  end
end

test("teams_oauth validates Graph-returned ids before building resources and receipts") do
  bad_ids = ["", " ", "a/b", "a\\b", "..", ".", "a%2Fb", "a%252F", 42, { "id" => "x" }, nil]
  bad_ids.each do |bad_id|
    transport = oauth_transport
    provider = oauth_provider
    transport.expect_json(:GET, %r{/chats/chat-1/messages}, body: {
                            "value" => [TeamsOauthCases.graph_message(bad_id,
                              created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                          })
    registry = oauth_registry(transport, provider)
    begin
      registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                      input: { "scope" => "chat/chat-1" },
                      context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
      raise "expected output rejection for #{bad_id.inspect}"
    rescue Aiconshell::Plugins::OutputInvalid => e
      expect(e.message).to match(/message|shape/)
    end
    transport.assert_consumed!
  end

  bad_receipts = ["", "reply/9", "a/b", "x%2Fy", 123, nil]
  bad_receipts.each do |bad_id|
    transport = oauth_transport
    provider = oauth_provider
    url = "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
    transport.expect_json(:POST, url, body: { "id" => bad_id })
    registry = oauth_registry(transport, provider)
    begin
      registry.invoke(plugin: "teams_oauth", operation: "send_message",
                      input: { "scope" => "channel:team-1/chan-1", "body" => "x" },
                      context: oauth_ctx(TeamsOauthCases::WRITE_SCOPES, provider))
      raise "expected receipt rejection for #{bad_id.inspect}"
    rescue Aiconshell::Plugins::OutputInvalid => e
      expect(e.details.first).to match(/message id/)
    end
    transport.assert_consumed!
  end
end

test("teams_oauth refuses noncanonical page paths before any follow-up") do
  chan = "19%3Achan%40thread.tacv2"
  bad_links = [
    "#{TeamsOauthCases::GRAPH_BASE}/v1.0/teams/team-1/channels/#{chan}/messages?$skiptoken=x",
    "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/#{chan}/messages/?$skiptoken=x",
    "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/#{chan}/messages//?$skiptoken=x",
    "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/./#{chan}/messages?$skiptoken=x",
    "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/#{chan}/messages/%2e?$skiptoken=x",
    "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan%2Fevil/messages?$skiptoken=x",
    "#{TeamsOauthCases::GRAPH_BASE}/teams/team-1/channels/chan%252Fevil/messages?$skiptoken=x",
    "https://user:secret@graph.microsoft.com/v1.0/teams/team-1/channels/#{chan}/messages?$skiptoken=x"
  ]
  # Wrong prefix, trailing slash, empty segments, dot segments, encoded
  # separators, double-encoding, and userinfo. All must fail before the
  # follow-up fetch.
  valid_first = TeamsOauthCases.channel_first_url
  bad_links.each do |link|
    transport = oauth_transport
    provider = oauth_provider
    transport.expect_json(:GET, valid_first, body: { "value" => [], "@odata.nextLink" => link })
    registry = oauth_registry(transport, provider)
    begin
      registry.invoke(plugin: "teams_oauth", operation: "latest_events",
                      input: { "scope" => TeamsOauthCases.channel_scope },
                      context: oauth_ctx(TeamsOauthCases::READ_SCOPES, provider))
      raise "expected pagination rejection for #{link}"
    rescue Aiconshell::Plugins::HostRejected, Aiconshell::Plugins::OutputInvalid
      nil
    end
    expect(transport.requests_to(%r{skiptoken=x}).size).to eq(0)
    transport.assert_consumed!
  end
end

test("teams_oauth inspect and to_s stay secret-free with an injected provider") do
  provider = oauth_provider(TeamsOauthCases::BINDING, token: "super-secret-token-123")
  adapter = Aiconshell::Plugins::TeamsOauth.new(oauth_credential_provider: provider)
  expect(adapter.inspect).to eq("#<Aiconshell::Plugins::TeamsOauth>")
  expect(adapter.to_s).to eq("#<Aiconshell::Plugins::TeamsOauth>")
  expect(adapter.inspect).not_to include("super-secret-token-123")
  expect(adapter.to_s).not_to include("super-secret-token-123")
  expect(JSON.generate([adapter.inspect, adapter.to_s])).not_to include("super-secret-token-123")
end

test("teams_oauth catalog exposes independent scopes and env-only configured flag") do
  transport = oauth_transport
  provider = oauth_provider
  registry = oauth_registry(transport, provider)
  entry = registry.catalog.find { |row| row["id"] == "teams_oauth" }

  expect(entry["required_env"]).to eq(["OAUTH_MICROSOFT_CLIENT_ID", "OAUTH_MICROSOFT_CLIENT_SECRET",
                                       "OAUTH_MICROSOFT_CLIENT_SECRET_FILE", "OAUTH_MICROSOFT_TENANT_ID",
                                       "OAUTH_MICROSOFT_REDIRECT_URI"])
  expect(entry["configured"]).to eq(true)
  by_name = entry["operations"].to_h { |op| [op["name"], op] }
  expect(by_name["latest_events"]["scope"]).to eq("teams_oauth:read")
  expect(by_name["latest_events"]["read_only"]).to eq(true)
  expect(by_name["reply"]["scope"]).to eq("teams_oauth:write")
  expect(by_name["send_message"]["scope"]).to eq("teams_oauth:write")
  expect(by_name["create_issue"]["unsupported"]).to eq(true)

  empty_registry = Aiconshell::Plugins::Registry.new(
    env: {}, transport: oauth_transport,
    clock: TeamsOauthCases::FixedClock.new(Time.utc(2026, 9, 26, 12, 0, 0))
  )
  empty_registry.register(Aiconshell::Plugins::TeamsOauth.new)
  empty_entry = empty_registry.catalog.find { |row| row["id"] == "teams_oauth" }
  expect(empty_entry["configured"]).to eq(false)
  expect(transport.requests).to eq([])
  transport.assert_consumed!
end
