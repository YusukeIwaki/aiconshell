# frozen_string_literal: true

require_relative "plugins_test_helper"

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
          "?$top=50&$filter=lastModifiedDateTime+gt+2026-09-26T11%3A00%3A00Z"
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
  expect(ids).to eq(["teams:message:m1", "teams:message:m2", "teams:reply:m1:r1"])
  expect(out["events"][1]["actor_type"]).to eq("bot")
  expect(out["events"][2]["resource_id"])
    .to eq("message:team-1/19:chan@thread.tacv2/r1")
  expect(out["events"][2]["payload"]["reply_to_id"]).to eq("m1")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T11:30:00Z" })

  graph_calls = transport.requests.select { |r| r[:url].start_with?(GRAPH) }
  expect(graph_calls.size).to eq(4)
  expect(graph_calls.map { |r| r[:headers]["Authorization"] }.uniq).to eq(["Bearer graph-token"])

  token_req = transport.requests_to(TOKEN_URL).first
  form = URI.decode_www_form(token_req[:body]).to_h
  expect(form["grant_type"]).to eq("client_credentials")
  expect(form["client_id"]).to eq("client-id")
  expect(form["scope"]).to eq("https://graph.microsoft.com/.default")
  # Secrets travel in POST bodies to the login host only, never in URLs.
  expect(token_req[:url]).not_to include("secret")
end

test("teams refuses cross-host nextLink and cursor URLs") do |registry:, transport:|
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
  end.to raise_error(Plugins::HostRejected, /evil\.test/)
  expect(transport.requests).to eq([])
end

test("teams reply and send_message post bot connector activities") do |registry:, transport:|
  teams_token_stubs(transport)
  activity_url = "https://service.example/v3/conversations/19%3Achan%40thread.tacv2/activities"
  transport.stub_json("POST", activity_url, body: { "id" => "act-1" })

  out = registry.invoke(plugin: "teams", operation: "reply",
                        input: { "resource_id" => "channel:team-1/19:chan@thread.tacv2",
                                 "body" => "replying" },
                        context: {})
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
