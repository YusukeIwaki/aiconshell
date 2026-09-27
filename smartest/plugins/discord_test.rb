# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins
DISCORD_API = "https://discord.com/api/v10"
DISCORD_CHANNEL = "123456789012345678"
DISCORD_BOT_ID = "999888777666555444"
DISCORD_USER_ID = "111222333444555666"
DISCORD_ME_URL = "#{DISCORD_API}/users/@me"
DISCORD_LIST_URL = "#{DISCORD_API}/channels/#{DISCORD_CHANNEL}/messages?limit=100"
DISCORD_POST_URL = "#{DISCORD_API}/channels/#{DISCORD_CHANNEL}/messages"

def discord_poll_scope
  "channel/#{DISCORD_CHANNEL}"
end

def stub_discord_self(transport, bot_id: DISCORD_BOT_ID)
  transport.stub_json("GET", DISCORD_ME_URL,
                      body: { "id" => bot_id, "username" => "aiconshell", "bot" => true })
end

def discord_message(id, content: "hello <@#{DISCORD_BOT_ID}>", mentions: [DISCORD_BOT_ID],
                    author: DISCORD_USER_ID, type: 0, bot: false, webhook: false,
                    timestamp: "2026-09-26T11:10:00.123456+00:00", edited: nil)
  message = {
    "id" => id.to_s, "type" => type, "content" => content, "channel_id" => DISCORD_CHANNEL,
    "author" => { "id" => author.to_s, "username" => "someone", "global_name" => "Someone", "bot" => bot },
    "mentions" => mentions.map { |user| { "id" => user.to_s, "username" => "mentioned" } },
    "mention_roles" => [],
    "timestamp" => timestamp, "edited_timestamp" => edited,
    "pinned" => false, "tts" => false
  }
  message["webhook_id"] = "777888999000111222" if webhook
  message
end

def discord_poll(registry, scope: discord_poll_scope, cursor: nil, context: {})
  registry.invoke(plugin: "discord", operation: "latest_events",
                  input: { "scope" => scope, "cursor" => cursor }, context: context)
end

test("discord poll accepts only structured bot mentions and advances the cursor") do |registry:, transport:|
  stub_discord_self(transport)
  transport.stub_json("GET", DISCORD_LIST_URL, body: [
                        discord_message("130000000000000010"),
                        discord_message("130000000000000009", content: "plain post", mentions: []),
                        discord_message("130000000000000008", content: "fake <@#{DISCORD_BOT_ID}> mention", mentions: []),
                        discord_message("130000000000000007", mentions: ["555666777888999000"]),
                        discord_message("130000000000000006", bot: true, author: DISCORD_BOT_ID),
                        discord_message("130000000000000005", webhook: true),
                        discord_message("130000000000000004", type: 6, mentions: [])
                      ])

  out = discord_poll(registry)

  expect(out["events"].size).to eq(1)
  event = out["events"].first
  expect(event["event_id"]).to eq("discord:message:#{DISCORD_CHANNEL}/130000000000000010")
  expect(event["event_type"]).to eq("discord.message")
  expect(event["resource_id"]).to eq("message:#{DISCORD_CHANNEL}/130000000000000010")
  expect(event["actor_id"]).to eq(DISCORD_USER_ID)
  expect(event["actor_type"]).to eq("human")
  expect(event["payload"]["body"]).to eq("hello <@#{DISCORD_BOT_ID}>")
  expect(event["payload"]["channel_id"]).to eq(DISCORD_CHANNEL)
  expect(event["payload"]["message_id"]).to eq("130000000000000010")
  expect(out["cursor"]).to eq({ "after" => "130000000000000010" })

  auth = transport.requests_to(DISCORD_ME_URL).first[:headers]["Authorization"]
  expect(auth).to eq("Bot discord-bot-token")
  list_auth = transport.requests_to(DISCORD_LIST_URL).first[:headers]["Authorization"]
  expect(list_auth).to eq("Bot discord-bot-token")
end

test("discord poll rejects non-snowflake scopes urls and traversal without I/O") do |registry:, transport:|
  %w[channel/abc channel/0 channel/00 channel/-1 channel/12ab
     channel/18446744073709551616 channel/99999999999999999999
     channel/../secret channel/%2e%2e/x channel//123].each do |scope|
    expect do
      registry.validate_input(plugin: "discord", operation: "latest_events",
                              input: { "scope" => scope }, context: {})
    end.to raise_error(Plugins::InputInvalid)
  end
  expect do
    registry.validate_input(plugin: "discord", operation: "latest_events",
                            input: { "scope" => "https://discord.com/channels/1/2" }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect do
    registry.invoke(plugin: "discord", operation: "latest_events",
                    input: { "scope" => "channel/not-an-id" }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect(transport.requests).to eq([])
end

test("discord poll rejects unknown cursor keys and invalid cursors without I/O") do |registry:, transport:|
  expect do
    registry.validate_input(plugin: "discord", operation: "latest_events",
                            input: { "scope" => discord_poll_scope, "cursor" => { "next" => "x" } }, context: {})
  end.to raise_error(Plugins::InputInvalid, /after/)
  expect do
    registry.validate_input(plugin: "discord", operation: "latest_events",
                            input: { "scope" => discord_poll_scope, "cursor" => { "after" => "abc" } }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect(transport.requests).to eq([])
end

test("discord poll rejects cross-channel responses") do |registry:, transport:|
  stub_discord_self(transport)
  transport.stub_json("GET", DISCORD_LIST_URL, body: [
                        discord_message("130000000000000010").merge("channel_id" => "000111222333444555")
                      ])

  expect { discord_poll(registry) }.to raise_error(Plugins::OutputInvalid, /another channel/)
end

test("discord poll pages past one hundred new messages without silent gaps") do |registry:, transport:|
  stub_discord_self(transport)
  first_ids = (101..200).map { |n| "130000000000000#{n}" }.reverse
  transport.stub_json("GET", DISCORD_LIST_URL,
                      body: first_ids.map { |id| discord_message(id) })
  oldest = first_ids.last
  second_ids = (51..100).map { |n| format("130000000000000%03d", n) }.reverse
  transport.stub_json("GET", "#{DISCORD_LIST_URL}&before=#{oldest}",
                      body: second_ids.map { |id| discord_message(id) })

  out = discord_poll(registry)

  expect(out["events"].size).to eq(150)
  expect(out["cursor"]).to eq({ "after" => first_ids.first })
  expect(transport.requests_to(%r{/messages}).size).to eq(2)
end

test("discord poll stops paging once the stored cursor is reached") do |registry:, transport:|
  stub_discord_self(transport)
  ids = (101..200).map { |n| "130000000000000#{n}" }.reverse
  transport.stub_json("GET", DISCORD_LIST_URL, body: ids.map { |id| discord_message(id) })

  out = discord_poll(registry, cursor: { "after" => "130000000000000150" })

  expect(out["events"].size).to eq(100)
  expect(out["cursor"]).to eq({ "after" => ids.first })
  expect(transport.requests_to(%r{/messages}).size).to eq(1)
end

test("discord poll fails incomplete on an unbounded backlog without a partial cursor") do |registry:, transport:|
  stub_discord_self(transport)
  transport.stub_proc("GET", %r{/channels/#{DISCORD_CHANNEL}/messages}) do |entry|
    before = entry[:url][%r{before=(\d+)}, 1]
    top = before ? before.to_i - 1 : 13_000_000_000_000_099
    ids = (0..99).map { |offset| (top - offset).to_s }
    Plugins::Http::Response.new(status: 200, headers: {},
                                body: JSON.generate(ids.map { |id| discord_message(id) }))
  end

  expect { discord_poll(registry) }.to raise_error(Plugins::IncompletePoll)
  expect(transport.requests_to(%r{/channels/#{DISCORD_CHANNEL}/messages}).size).to eq(10)
end

test("discord poll surfaces edited mentions with a new fingerprint and update time") do |registry:, transport:|
  stub_discord_self(transport)
  calls = 0
  transport.stub_proc("GET", DISCORD_LIST_URL) do |_entry|
    calls += 1
    body = if calls == 1
             [discord_message("130000000000000010", content: "first")]
           else
             [discord_message("130000000000000010", content: "second",
                              edited: "2026-09-26T11:20:00.000000+00:00")]
           end
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate(body))
  end
  first = discord_poll(registry)["events"].first
  second = discord_poll(registry, cursor: { "after" => "130000000000000009" })["events"].first

  expect(first["fingerprint"]).not_to eq(second["fingerprint"])
  expect(second["occurred_at"]).to eq("2026-09-26T11:20:00Z")
  expect(second["payload"]["edited"]).to eq(true)
  expect(second["payload"]["body"]).to eq("second")
end

test("discord reply posts a message reference with mentions disabled") do |registry:, transport:|
  transport.stub_json("POST", DISCORD_POST_URL, status: 200, body: { "id" => "140000000000000001" })

  out = registry.invoke(plugin: "discord", operation: "reply",
                        input: { "resource_id" => "message:#{DISCORD_CHANNEL}/130000000000000010",
                                 "body" => "working on it" },
                        context: {})

  expect(out).to eq({ "external_id" => "140000000000000001", "url" => nil })
  post = transport.requests_to(DISCORD_POST_URL).first
  expect(post[:headers]["Authorization"]).to eq("Bot discord-bot-token")
  payload = JSON.parse(post[:body])
  expect(payload["content"]).to eq("working on it")
  expect(payload["message_reference"]).to eq({ "message_id" => "130000000000000010" })
  expect(payload["allowed_mentions"]).to eq({ "parse" => [], "replied_user" => false })
  expect(transport.requests_to(DISCORD_ME_URL).size).to eq(0)
end

test("discord send_message posts to the channel without a reference") do |registry:, transport:|
  transport.stub_json("POST", DISCORD_POST_URL, status: 200, body: { "id" => "140000000000000002" })

  out = registry.invoke(plugin: "discord", operation: "send_message",
                        input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => "notify" },
                        context: {})

  expect(out).to eq({ "external_id" => "140000000000000002", "url" => nil })
  payload = JSON.parse(transport.requests_to(DISCORD_POST_URL).first[:body])
  expect(payload["message_reference"]).to eq(nil)
  expect(payload["allowed_mentions"]).to eq({ "parse" => [], "replied_user" => false })
end

test("discord rejects overlong empty and invalid bodies before any HTTP") do |registry:, transport:|
  long_body = "x" * 2001
  expect do
    registry.validate_input(plugin: "discord", operation: "reply",
                            input: { "resource_id" => "message:#{DISCORD_CHANNEL}/130000000000000010",
                                     "body" => long_body }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect do
    registry.invoke(plugin: "discord", operation: "send_message",
                    input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => long_body }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect do
    registry.validate_input(plugin: "discord", operation: "reply",
                            input: { "resource_id" => "message:#{DISCORD_CHANNEL}/130000000000000010",
                                     "body" => "" }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect do
    registry.validate_input(plugin: "discord", operation: "reply",
                            input: { "resource_id" => "message:not-an-id/also-bad", "body" => "hi" }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect do
    registry.validate_input(plugin: "discord", operation: "send_message",
                            input: { "scope" => "channel:not-an-id", "body" => "hi" }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect(transport.requests).to eq([])
end

test("discord classifies rate limits auth failures timeouts and bad payloads safely") do |registry:, transport:|
  transport.stub_json("POST", DISCORD_POST_URL, status: 429,
                      headers: { "Retry-After" => "1.5" }, body: { "retry_after" => 1.5, "global" => false })
  begin
    registry.invoke(plugin: "discord", operation: "send_message",
                    input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => "hi" }, context: {})
    raise "expected RateLimited"
  rescue Plugins::RateLimited => error
    expect(error.retry_after).to eq(2)
    expect(error.message).not_to include("discord-bot-token")
  end

  transport2 = FakeTransport.new(clock: Time.utc(2026, 9, 26, 12, 0, 0))
  env = { "DISCORD_BOT_TOKEN" => "discord-bot-token" }
  registry2 = Plugins::Registry.new(env: env, transport: transport2)
  registry2.register(Plugins::Discord.new)
  transport2.stub_json("POST", DISCORD_POST_URL, status: 401, body: { "message" => "401: Unauthorized" })
  begin
    registry2.invoke(plugin: "discord", operation: "send_message",
                     input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => "hi" }, context: {})
    raise "expected HttpError"
  rescue Plugins::HttpError => error
    expect(error.status).to eq(401)
    expect(error.message).not_to include("discord-bot-token")
  end

  transport3 = FakeTransport.new(clock: Time.utc(2026, 9, 26, 12, 0, 0))
  registry3 = Plugins::Registry.new(env: env, transport: transport3)
  registry3.register(Plugins::Discord.new)
  transport3.stub_proc("POST", DISCORD_POST_URL) do |entry|
    raise Plugins::TransportTimeout.new(http_method: entry[:method], url: entry[:url], timeout_kind: "read")
  end
  expect do
    registry3.invoke(plugin: "discord", operation: "send_message",
                     input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => "hi" }, context: {})
  end.to raise_error(Plugins::TransportTimeout)

  transport4 = FakeTransport.new(clock: Time.utc(2026, 9, 26, 12, 0, 0))
  registry4 = Plugins::Registry.new(env: env, transport: transport4)
  registry4.register(Plugins::Discord.new)
  transport4.stub_proc("POST", DISCORD_POST_URL) do |_entry|
    Plugins::Http::Response.new(status: 200, headers: {}, body: "{invalid json")
  end
  expect do
    registry4.invoke(plugin: "discord", operation: "send_message",
                     input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => "hi" }, context: {})
  end.to raise_error(Plugins::OutputInvalid)

  transport5 = FakeTransport.new(clock: Time.utc(2026, 9, 26, 12, 0, 0))
  registry5 = Plugins::Registry.new(env: env, transport: transport5)
  registry5.register(Plugins::Discord.new)
  transport5.stub_json("POST", DISCORD_POST_URL, status: 200, body: { "unexpected" => true })
  expect do
    registry5.invoke(plugin: "discord", operation: "reply",
                     input: { "resource_id" => "message:#{DISCORD_CHANNEL}/130000000000000010",
                              "body" => "hi" }, context: {})
  end.to raise_error(Plugins::OutputInvalid, /message id/)
end

test("discord create_issue is unsupported and credentials stay required") do |registry:, transport:, plugin_env:|
  expect do
    registry.invoke(plugin: "discord", operation: "create_issue",
                    input: { "scope" => "x", "title" => "t", "body" => "b" }, context: {})
  end.to raise_error(Plugins::UnsupportedOperation, /no issue tracker/i)

  plugin_env.delete("DISCORD_BOT_TOKEN")
  expect do
    registry.invoke(plugin: "discord", operation: "send_message",
                    input: { "scope" => "channel:#{DISCORD_CHANNEL}", "body" => "hi" }, context: {})
  end.to raise_error(Plugins::CredentialsMissing, /DISCORD_BOT_TOKEN/)
  expect do
    discord_poll(registry)
  end.to raise_error(Plugins::CredentialsMissing, /DISCORD_BOT_TOKEN/)
  expect(transport.requests).to eq([])
end

test("discord enforces discord read and write scopes") do |registry:, transport:|
  stub_discord_self(transport)
  transport.stub_json("GET", DISCORD_LIST_URL, body: [])

  expect do
    discord_poll(registry, context: { "scopes" => ["discord:write"] })
  end.to raise_error(Plugins::PermissionDenied, /discord:read/)
  expect(transport.requests).to eq([])

  expect do
    registry.invoke(plugin: "discord", operation: "reply",
                    input: { "resource_id" => "message:#{DISCORD_CHANNEL}/130000000000000010",
                             "body" => "hi" },
                    context: { "scopes" => ["discord:read"] })
  end.to raise_error(Plugins::PermissionDenied, /discord:write/)
  expect(transport.requests).to eq([])

  out = discord_poll(registry, context: { "scopes" => ["discord:read"] })
  expect(out["events"]).to eq([])
end
