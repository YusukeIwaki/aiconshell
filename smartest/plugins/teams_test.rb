# frozen_string_literal: true

require_relative "plugins_test_helper"
require "tempfile"

Plugins = Aiconshell::Plugins
GRAPH = "https://graph.microsoft.com"
TOKEN_URL = "https://login.microsoftonline.com/tenant-id/oauth2/v2.0/token"

def teams_token_stubs(transport)
  transport.stub_proc("POST", TOKEN_URL) do |req|
    form = URI.decode_www_form(req[:body]).to_h
    scope = form["scope"]
    token = scope.include?("graph.microsoft.com") ? "graph-token" : "bot-token"
    Plugins::Http::Response.new(status: 200, headers: {},
                                body: JSON.generate({ "access_token" => token,
                                                      "expires_in" => 3600 }))
  end
end

def teams_message(id, created:, modified:, from: { "user" => { "id" => "u1" } },
                  reply_to: nil, body: "hello")
  { "id" => id, "createdDateTime" => created, "lastModifiedDateTime" => modified,
    "etag" => "etag-#{id}", "subject" => nil, "replyToId" => reply_to,
    "from" => from,
    "body" => { "content" => body, "contentType" => "text" },
    "webUrl" => "https://teams.test/m/#{id}" }
end

def teams_poll_scope
  "team/team-1/channel/19:chan@thread.tacv2"
end

test("teams poll reads graph messages plus replies with paging") do |registry:, transport:|
  teams_token_stubs(transport)
  first = "#{GRAPH}/v1.0/teams/team-1/channels/19%3Achan%40thread.tacv2/messages" \
          "?$top=50"
  nxt = "#{GRAPH}/v1.0/teams/team-1/channels/chan/messages?$skiptoken=abc"
  transport.stub_json("GET", first, body: {
                        "value" => [teams_message("m1", created: "2026-09-26T11:10:00Z",
                                                       modified: "2026-09-26T11:10:00Z")],
                        "@odata.nextLink" => nxt
                      })
  transport.stub_json("GET", nxt, body: {
                        "value" => [teams_message("m2", created: "2026-09-26T11:20:00Z",
                                                       modified: "2026-09-26T11:25:00Z",
                                                       from: { "application" => { "id" => "app1" } })]
                      })
  transport.stub_json("GET", %r{/messages/m1/replies}, body: {
                        "value" => [teams_message("r1", created: "2026-09-26T11:30:00Z",
                                                       modified: "2026-09-26T11:30:00Z",
                                                       reply_to: "m1", body: "reply")]
                      })
  transport.stub_json("GET", %r{/messages/m2/replies}, body: { "value" => [] })

  out = registry.invoke(plugin: "teams", operation: "latest_events",
                        input: { "scope" => teams_poll_scope,
                                 "cursor" => { "since" => "2026-09-26T11:00:00Z" } },
                        context: {})

  ids = out["events"].map { |e| e["event_id"] }
  expect(ids).to eq(["teams:message:team-1/19%3Achan%40thread.tacv2/m1",
                     "teams:message:team-1/19%3Achan%40thread.tacv2/m2",
                     "teams:reply:team-1/19%3Achan%40thread.tacv2/m1/r1"])
  expect(out["events"][1]["actor_type"]).to eq("bot")
  expect(out["events"][2]["resource_id"])
    .to eq("message:team-1/19:chan@thread.tacv2/m1")
  expect(out["events"][2]["payload"]["reply_to_id"]).to eq("m1")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T11:30:00Z" })

  graph_calls = transport.requests.select { |r| r[:url].start_with?(GRAPH) }
  expect(graph_calls.size).to eq(4)
  expect(graph_calls.map { |r| r[:headers]["Authorization"] }.uniq).to eq(["Bearer graph-token"])
  expect(graph_calls.any? { |request| request[:url].include?("$filter") }).to eq(false)

  token_req = transport.requests_to(TOKEN_URL).first
  form = URI.decode_www_form(token_req[:body]).to_h
  expect(form["grant_type"]).to eq("client_credentials")
  expect(form["client_id"]).to eq("client-id")
  expect(form["scope"]).to eq("https://graph.microsoft.com/.default")
  # Secrets travel in POST bodies to the login host only, never in URLs.
  expect(token_req[:url]).not_to include("secret")
end

test("teams refuses cross-host nextLink and unsupported cursor URLs") do |registry:, transport:|
  teams_token_stubs(transport)
  first = "#{GRAPH}/v1.0/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$top=50"
  transport.stub_json("GET", first, body: {
                        "value" => [], "@odata.nextLink" => "https://evil.test/next"
                      })
  expect do
    registry.invoke(plugin: "teams", operation: "latest_events",
                    input: { "scope" => teams_poll_scope }, context: {})
  end.to raise_error(Plugins::HostRejected, /evil\.test/)
  expect(transport.requests_to(%r{evil\.test}).size).to eq(0)

  transport.requests.clear
  expect do
    registry.invoke(plugin: "teams", operation: "latest_events",
                    input: { "scope" => teams_poll_scope,
                             "cursor" => { "next" => "https://evil.test/resume" } },
                    context: {})
  end.to raise_error(Plugins::InputInvalid, /only supports since/)
  expect(transport.requests).to eq([])
end

test("teams reply and send_message post bot connector activities") do |registry:, transport:|
  teams_token_stubs(transport)
  activity_url = "https://service.example/v3/conversations/actual-bot-conversation/activities"
  transport.stub_json("POST", activity_url, body: { "id" => "act-1" })

  out = registry.invoke(plugin: "teams", operation: "reply",
                        input: { "resource_id" => "channel:team-1/19:chan@thread.tacv2",
                                 "body" => "replying" },
                        context: { "teams_bot_targets" => {
                          "channel:team-1/19:chan@thread.tacv2" => { "conversation_id" => "actual-bot-conversation" }
                        } })
  expect(out).to eq({ "external_id" => "act-1", "url" => nil })
  req = transport.requests_to(activity_url).first
  expect(req[:headers]["Authorization"]).to eq("Bearer bot-token")
  expect(JSON.parse(req[:body])).to eq({ "type" => "message", "text" => "replying" })

  bot_token_req = transport.requests_to(TOKEN_URL).find do |r|
    URI.decode_www_form(r[:body]).to_h["scope"] == "https://api.botframework.com/.default"
  end
  expect(bot_token_req.nil?).to eq(false)
  bot_form = URI.decode_www_form(bot_token_req[:body]).to_h
  expect(bot_form["client_id"]).to eq("bot-app-id")

  thread_url = "https://service.example/v3/conversations/conv-9/activities"
  transport.stub_json("POST", thread_url, body: { "id" => "act-2" })
  out = registry.invoke(plugin: "teams", operation: "send_message",
                        input: { "scope" => "conversation:conv-9", "body" => "broadcast" },
                        context: {})
  expect(out["external_id"]).to eq("act-2")

  expect do
    registry.invoke(plugin: "teams", operation: "send_message",
                    input: { "scope" => "message:team-1/chan/m1", "body" => "x" },
                    context: {})
  end.to raise_error(Plugins::InputInvalid, /conversation/)
end

test("teams create_issue stays unsupported") do |registry:, transport:|
  expect do
    registry.invoke(plugin: "teams", operation: "create_issue",
                    input: { "scope" => teams_poll_scope, "title" => "t", "body" => "b" },
                    context: {})
  end.to raise_error(Plugins::UnsupportedOperation)
  expect(transport.requests).to eq([])
end

test("teams reads work without bot credentials; writes fail closed") do |registry:, transport:, plugin_env:|
  plugin_env.delete("TEAMS_BOT_APP_ID")
  plugin_env.delete("TEAMS_BOT_APP_PASSWORD")
  plugin_env.delete("TEAMS_SERVICE_URL")

  teams_token_stubs(transport)
  transport.stub_json("GET", %r{/messages\?}, body: { "value" => [] })
  out = registry.invoke(plugin: "teams", operation: "latest_events",
                        input: { "scope" => teams_poll_scope }, context: {})
  expect(out["events"]).to eq([])

  count = transport.requests.size
  expect do
    registry.invoke(plugin: "teams", operation: "send_message",
                    input: { "scope" => "conversation:conv-1", "body" => "x" },
                    context: {})
  end.to raise_error(Plugins::CredentialsMissing, /TEAMS_SERVICE_URL/)
  expect(transport.requests.size).to eq(count)
end

test("teams requires tenant and client credentials before I/O") do |registry:, transport:, plugin_env:|
  plugin_env.delete("TEAMS_TENANT_ID")
  expect do
    registry.invoke(plugin: "teams", operation: "latest_events",
                    input: { "scope" => teams_poll_scope }, context: {})
  end.to raise_error(Plugins::CredentialsMissing, /TEAMS_TENANT_ID/)
  expect(transport.requests).to eq([])
end

test("teams finds a new reply on an old root and compares timestamps as instants") do |registry:, transport:|
  teams_token_stubs(transport)
  transport.stub_json("GET", %r{/messages\?}, body: {
                        "value" => [teams_message("old-root", created: "2026-01-01T12:00:00Z",
                                                              modified: "2026-01-01T12:00:00Z")]
                      })
  replies = [teams_message("recent", created: "2026-09-26T05:01:00-07:00", modified: "2026-09-26T05:01:00-07:00"),
             teams_message("equal", created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z"),
             teams_message("delayed", created: "2026-09-26T11:55:00Z", modified: "2026-09-26T11:55:00Z"),
             teams_message("old", created: "2026-09-26T20:00:00+09:00", modified: "2026-09-26T20:00:00+09:00")]
  transport.stub_json("GET", %r{/messages/old-root/replies}, body: { "value" => replies })
  out = registry.invoke(plugin: "teams", operation: "latest_events",
                        input: { "scope" => teams_poll_scope, "cursor" => { "since" => "2026-09-26T12:00:00Z" } })
  expect(out["events"].map { |event| event["payload"]["message_id"] }).to eq(%w[delayed equal recent])
  expect(out["events"].map { |event| event["resource_id"] }.uniq).to eq(["message:team-1/19:chan@thread.tacv2/old-root"])
  expect(out["events"].last["occurred_at"]).to eq("2026-09-26T12:01:00Z")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:01:00Z" })
  expect(transport.requests.any? { |request| request[:url].include?("$filter") }).to eq(false)
end

test("teams expands all roots across more than fifty messages") do |registry:, transport:|
  teams_token_stubs(transport)
  first = "#{GRAPH}/v1.0/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$top=50"
  nxt = "#{GRAPH}/v1.0/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$skiptoken=next"
  messages = (1..51).map { |number| teams_message("m#{number}", created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z") }
  transport.stub_json("GET", first, body: { "value" => messages.first(50), "@odata.nextLink" => nxt })
  transport.stub_json("GET", nxt, body: { "value" => [messages.last] })
  transport.stub_json("GET", %r{/messages/m51/replies}, body: {
                        "value" => [teams_message("r51", created: "2026-09-26T12:01:00Z", modified: "2026-09-26T12:01:00Z")]
                      })
  transport.stub_json("GET", %r{/messages/[^/]+/replies}, body: { "value" => [] })
  out = registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
  expect(out["events"].size).to eq(52)
  expect(out["events"].last["payload"]["message_id"]).to eq("r51")
  expect(transport.requests_to(%r{/replies}).size).to eq(51)
end

test("teams returns every reply across more than fifty replies") do |registry:, transport:|
  teams_token_stubs(transport)
  transport.stub_json("GET", %r{/messages\?}, body: {
                        "value" => [teams_message("m1", created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                      })
  nxt = "#{GRAPH}/v1.0/teams/team-1/channels/chan/messages/m1/replies?$skiptoken=next"
  replies = (1..51).map { |number| teams_message("r#{number}", created: "2026-09-26T12:01:00Z", modified: "2026-09-26T12:01:00Z") }
  transport.stub_json("GET", nxt, body: { "value" => [replies.last] })
  transport.stub_json("GET", %r{/messages/m1/replies}, body: { "value" => replies.first(50), "@odata.nextLink" => nxt })
  out = registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
  expect(out["events"].count { |event| event["event_type"] == "teams.reply" }).to eq(51)
end

%w[messages replies].each do |endpoint|
  test("teams raises incomplete poll at the #{endpoint} page cap without changing the cursor") do |registry:, transport:|
    teams_token_stubs(transport)
    if endpoint == "replies"
      transport.stub_json("GET", %r{/messages\?}, body: {
                            "value" => [teams_message("m1", created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                          })
    end
    page = 0
    transport.stub_proc("GET", %r{/#{endpoint}\?}) do |_request|
      page += 1
      nxt = "#{GRAPH}/v1.0/teams/team-1/channels/chan/#{endpoint}?$skiptoken=#{page}"
      Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate({ "value" => [], "@odata.nextLink" => nxt }))
    end
    cursor = { "since" => "2026-09-26T11:00:00Z" }
    expect do
      registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope, "cursor" => cursor })
    end.to raise_error(Plugins::IncompletePoll, /page limit/)
    expect(page).to eq(Plugins::Teams::MAX_PAGES)
    expect(cursor).to eq({ "since" => "2026-09-26T11:00:00Z" })
  end
end

test("teams rejects pagination cycles without returning partial data") do |registry:, transport:|
  teams_token_stubs(transport)
  first = "#{GRAPH}/v1.0/teams/team-1/channels/19%3Achan%40thread.tacv2/messages?$top=50"
  transport.stub_json("GET", first, body: { "value" => [], "@odata.nextLink" => first })
  expect do
    registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
  end.to raise_error(Plugins::IncompletePoll, /did not advance/)
  expect(transport.requests_to(first).size).to eq(1)
end

test("teams rejects invalid cursors before obtaining a token") do |registry:, transport:|
  ["2026-02-30T12:00:00Z", "2026-09-26T12:00:00", "2026-09-26T24:00:00Z", "not-a-date", 42].each do |since|
    expect do
      registry.invoke(plugin: "teams", operation: "latest_events",
                      input: { "scope" => teams_poll_scope, "cursor" => { "since" => since } })
    end.to raise_error(Plugins::InputInvalid, /ISO8601/)
  end
  expect(transport.requests).to eq([])
end

test("teams rejects invalid remote timestamps without advancing its cursor") do |registry:, transport:|
  teams_token_stubs(transport)
  transport.stub_json("GET", %r{/messages\?}, body: {
                        "value" => [teams_message("m1", created: "2026-09-26T12:00:00Z", modified: "2026-02-30T12:00:00Z")]
                      })
  expect do
    registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
  end.to raise_error(Plugins::OutputInvalid, /timestamp/)
end

test("teams scopes otherwise identical event ids by team and channel") do |registry:, transport:|
  teams_token_stubs(transport)
  transport.stub_json("GET", %r{/messages\?}, body: {
                        "value" => [teams_message("same-id", created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                      })
  transport.stub_json("GET", %r{/replies\?}, body: {
                        "value" => [teams_message("same-reply", created: "2026-09-26T12:01:00Z", modified: "2026-09-26T12:01:00Z")]
                      })
  events = ["team/team-1/channel/channel-1", "team/team-2/channel/channel-1", "team/team-1/channel/channel-2"].flat_map do |scope|
    registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => scope })["events"]
  end
  expect(events.map { |event| event["event_id"] }.uniq.size).to eq(6)
  expect(events.map { |event| event["resource_id"] }.uniq.size).to eq(3)
end

test("teams returns edits at equal timestamps with a new fingerprint") do |registry:, transport:|
  teams_token_stubs(transport)
  version = 0
  transport.stub_proc("GET", %r{/messages\?}) do |_request|
    version += 1
    message = teams_message("m1", created: "2026-09-26T11:00:00Z", modified: "2026-09-26T12:00:00Z", body: "version #{version}")
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate({ "value" => [message] }))
  end
  transport.stub_json("GET", %r{/replies\?}, body: { "value" => [] })
  before = registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
  after = registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope, "cursor" => before["cursor"] })
  expect(after["events"].first["event_id"]).to eq(before["events"].first["event_id"])
  expect(after["events"].first["fingerprint"]).not_to eq(before["events"].first["fingerprint"])
  expect(after["events"].first["occurred_at"]).to eq("2026-09-26T12:00:00Z")
end

test("teams rejects unsafe same-host Graph next links") do |registry:, transport:|
  teams_token_stubs(transport)
  links = ["http://graph.microsoft.com/next", "https://graph.microsoft.com:8443/next", "https://user:secret@graph.microsoft.com/next"]
  transport.stub_proc("GET", %r{/messages\?}) do |_request|
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate({ "value" => [], "@odata.nextLink" => links.shift }))
  end
  3.times do
    expect do
      registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
    end.to raise_error(Plugins::HostRejected)
  end
  expect(transport.requests_to(%r{/next}).size).to eq(0)
end

test("teams replies to a polled resource through its actual Bot conversation and activity mapping") do |registry:, transport:|
  teams_token_stubs(transport)
  transport.stub_json("GET", %r{/messages\?}, body: {
                        "value" => [teams_message("graph-root", created: "2026-09-26T12:00:00Z", modified: "2026-09-26T12:00:00Z")]
                      })
  transport.stub_json("GET", %r{/replies\?}, body: {
                        "value" => [teams_message("graph-reply", created: "2026-09-26T12:01:00Z", modified: "2026-09-26T12:01:00Z")]
                      })
  out = registry.invoke(plugin: "teams", operation: "latest_events", input: { "scope" => teams_poll_scope })
  resource = out["events"].last["resource_id"]
  expect(resource).to eq("message:team-1/19:chan@thread.tacv2/graph-root")
  activity_url = "https://service.example/v3/conversations/bot-conversation%3Bthread/activities/bot-activity"
  transport.stub_json("POST", activity_url, body: { "id" => "sent-activity" })
  result = registry.invoke(plugin: "teams", operation: "reply", input: { "resource_id" => resource, "body" => "ack" },
                           context: { "teams_bot_targets" => { resource => { "conversation_id" => "bot-conversation;thread", "activity_id" => "bot-activity" } } })
  expect(result).to eq({ "external_id" => "sent-activity", "url" => nil })
  request = transport.requests_to(activity_url).first
  expect(JSON.parse(request[:body])).to eq({ "type" => "message", "text" => "ack", "replyToId" => "bot-activity" })
  expect(request[:headers]["Authorization"]).to eq("Bearer bot-token")
end

test("teams loads Bot mappings from a private file for channel sends and message replies") do |registry:, transport:, plugin_env:|
  teams_token_stubs(transport)
  Tempfile.create("teams-bot-targets") do |file|
    file.write(JSON.generate({
      "channel:team-1/channel-1" => { "conversation_id" => "actual-conversation" },
      "message:team-1/channel-1/root" => { "conversation_id" => "actual-thread", "activity_id" => "actual-activity" }
    }))
    file.flush
    plugin_env["TEAMS_BOT_TARGETS_FILE"] = file.path
    send_url = "https://service.example/v3/conversations/actual-conversation/activities"
    reply_url = "https://service.example/v3/conversations/actual-thread/activities/actual-activity"
    transport.stub_json("POST", send_url, body: { "id" => "sent" })
    transport.stub_json("POST", reply_url, body: { "id" => "replied" })
    sent = registry.invoke(plugin: "teams", operation: "send_message", input: { "scope" => "channel:team-1/channel-1", "body" => "hello" })
    replied = registry.invoke(plugin: "teams", operation: "reply", input: { "resource_id" => "message:team-1/channel-1/root", "body" => "ack" })
    expect(sent["external_id"]).to eq("sent")
    expect(replied["external_id"]).to eq("replied")
  end
end

test("teams fails before I/O when Graph write targets lack actual Bot references") do |registry:, transport:|
  ["message:team-1/channel-1/root", "channel:team-1/channel-1"].each do |target|
    expect do
      registry.invoke(plugin: "teams", operation: "reply", input: { "resource_id" => target, "body" => "ack" })
    end.to raise_error(Plugins::CredentialsMissing, /TEAMS_BOT_TARGETS_FILE/)
  end
  target = "message:team-1/channel-1/root"
  expect do
    registry.invoke(plugin: "teams", operation: "reply", input: { "resource_id" => target, "body" => "ack" },
                    context: { "teams_bot_targets" => { target => { "conversation_id" => "known-conversation" } } })
  end.to raise_error(Plugins::CredentialsMissing, /mapping/)
  expect(transport.requests).to eq([])
end

test("teams validates Bot mappings without exposing file contents or paths") do |registry:, transport:, plugin_env:|
  target = "message:team-1/channel-1/root"
  Tempfile.create("teams-private-path") do |file|
    file.write("private-content-not-json")
    file.flush
    plugin_env["TEAMS_BOT_TARGETS_FILE"] = file.path
    begin
      registry.invoke(plugin: "teams", operation: "reply", input: { "resource_id" => target, "body" => "ack" })
      raise "expected invalid mapping"
    rescue Plugins::CredentialsMissing => error
      expect(error.message).not_to include(file.path)
      expect(error.message).not_to include("private-content")
    end
  end
  [[], { target => { "conversation_id" => 42 } }, { target => { "conversation_id" => "c", "service_url" => "https://evil.test" } }].each do |mapping|
    expect do
      registry.invoke(plugin: "teams", operation: "reply", input: { "resource_id" => target, "body" => "ack" },
                      context: { "teams_bot_targets" => mapping })
    end.to raise_error(Plugins::CredentialsMissing, /valid Bot references/)
  end
  expect(transport.requests).to eq([])
end

test("teams explicit conversation activity references use the reply endpoint") do |registry:, transport:|
  teams_token_stubs(transport)
  url = "https://service.example/v3/conversations/known-conversation/activities/known-activity"
  transport.stub_json("POST", url, body: { "id" => "reply" })
  out = registry.invoke(plugin: "teams", operation: "reply",
                        input: { "resource_id" => "conversation:known-conversation/known-activity", "body" => "hello" })
  expect(out["external_id"]).to eq("reply")
  expect(JSON.parse(transport.requests_to(url).first[:body])["replyToId"]).to eq("known-activity")
end
