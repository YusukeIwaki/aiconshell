# frozen_string_literal: true

require "db_helper"
require "aiconshell/plugins"
require_relative "workflow_test_helper"
require_relative "../../support/boundary_fixtures"

# Discord vertical slice with the real Registry and Discord adapter (issue
# #27). Only the HTTP boundary is scripted through finite
# BoundaryFixtures::HttpTransport expectations and the AI boundary through
# WorkflowFakes::FakeAiRunner. Poll, triage, delivery, admin notification,
# and reconciliation all run as real services against PostgreSQL.
DISCORD_CHANNEL = "123456789012345678"
DISCORD_BOT_ID = "999888777666555444"
DISCORD_USER_ID = "111222333444555666"
DISCORD_API = "https://discord.com/api/v10"
DISCORD_ME_URL = "#{DISCORD_API}/users/@me"
DISCORD_LIST_URL = "#{DISCORD_API}/channels/#{DISCORD_CHANNEL}/messages?limit=100"
DISCORD_POST_URL = "#{DISCORD_API}/channels/#{DISCORD_CHANNEL}/messages"

DISCORD_TEST_ENV = { "DISCORD_BOT_TOKEN" => "integration-bot-token" }.freeze

def discord_registry(transport)
  Aiconshell::Plugins::Registry.new(env: {}, transport: transport)
    .register(Aiconshell::Plugins::Discord.new)
end

def discord_credentials
  WorkflowFakes::FakeCredentialSource.new("discord" => DISCORD_TEST_ENV)
end

def discord_event_message(id, content: "please help <@#{DISCORD_BOT_ID}>", mentions: [DISCORD_BOT_ID],
                          author: DISCORD_USER_ID, type: 0, bot: false, webhook: false,
                          timestamp: "2026-09-27T10:00:00.000000+00:00", edited: nil)
  message = {
    "id" => id.to_s, "type" => type, "content" => content, "channel_id" => DISCORD_CHANNEL,
    "author" => { "id" => author.to_s, "username" => "someone", "bot" => bot },
    "mentions" => mentions.map { |user| { "id" => user.to_s, "username" => "mentioned" } },
    "mention_roles" => [],
    "timestamp" => timestamp, "edited_timestamp" => edited,
    "pinned" => false, "tts" => false
  }
  message["webhook_id"] = "777888999000111222" if webhook
  message
end

def stub_discord_poll(transport, messages)
  transport.expect_json(:GET, DISCORD_ME_URL,
                        body: { "id" => DISCORD_BOT_ID, "username" => "aiconshell", "bot" => true })
  transport.expect_json(:GET, DISCORD_LIST_URL, body: messages)
end

def discord_poller(registry, sink)
  Interaction::PollService.new(registry: registry, event_sink: sink, credential_source: discord_credentials)
end

def discord_sender(registry, sink, ai)
  Interaction::OutboundService.new(registry: registry, ai_runner: ai, event_sink: sink,
    credential_source: discord_credentials)
end

test("discord mention flows from poll to task to triage reply to sent delivery") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)
    ai = WorkflowFakes::FakeAiRunner.new(answers: {})

    # 1. Poll ingests only the mention; plain posts never become events.
    stub_discord_poll(transport, [
                        discord_event_message("130000000000000010"),
                        discord_event_message("130000000000000009", content: "plain post", mentions: [])
                      ])
    poll = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(poll.ok).to eq(true)
    expect(poll.ingested).to eq(1)
    expect(ExternalEvent.count).to eq(1)
    event = ExternalEvent.last
    expect(event.event_type).to eq("discord.message")
    expect(event.resource_id).to eq("message:#{DISCORD_CHANNEL}/130000000000000010")
    expect(IntegrationCursor.find_by(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}").cursor)
      .to eq({ "after" => "130000000000000010" })

    # 2. Coordination ingests the mention into a task (no policy yet, so no
    # AI ruling and no backoff), then rules a reply once enabled.
    triage = Coordination::TriageService.new(ai_runner: ai, registry: registry, event_sink: sink,
      credential_source: discord_credentials)
    expect(triage.call.ingested).to eq(1)
    task = Task.last
    expect(task.source_plugin).to eq("discord")
    expect(task.description).to include("please help")
    LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    ai.instance_variable_get(:@answers)["coordination"] = {
      "rulings" => [{ "task_id" => task.id, "reply" => { "body" => "acknowledged" } }]
    }
    ruled = triage.call
    expect(ruled.triaged).to eq(1)
    action = OutboundAction.last
    expect(action.plugin).to eq("discord")
    expect(action.operation).to eq("reply")
    expect(action.input["resource_id"]).to eq("message:#{DISCORD_CHANNEL}/130000000000000010")

    # 3. Interaction delivers the reply through message_reference.
    transport.expect_json(:POST, DISCORD_POST_URL, body: { "id" => "140000000000000001" })
    delivery = discord_sender(registry, sink, ai).call(action.id)
    expect(delivery.ok).to eq(true)
    expect(action.reload.status).to eq("sent")
    expect(action.external_id).to eq("140000000000000001")
    payload = JSON.parse(transport.requests_to(DISCORD_POST_URL).first[:body])
    expect(payload["message_reference"]).to eq({ "message_id" => "130000000000000010" })
    expect(payload["allowed_mentions"]).to eq({ "parse" => [], "replied_user" => false })

    # 4. Re-polling the same post adds no task and no send.
    stub_discord_poll(transport, [discord_event_message("130000000000000010")])
    again = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(again.ok).to eq(true)
    expect(again.ingested).to eq(0)
    expect(Task.count).to eq(1)
    expect(OutboundAction.count).to eq(1)

    transport.assert_consumed!
  end
end

test("discord edit revisions attach to the same task without duplicating sends") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)

    stub_discord_poll(transport, [discord_event_message("130000000000000010", content: "first")])
    expect(discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}").ingested).to eq(1)

    stub_discord_poll(transport, [discord_event_message("130000000000000010", content: "second",
                                                        edited: "2026-09-27T10:05:00.000000+00:00")])
    edited = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(edited.ok).to eq(true)
    expect(edited.ingested).to eq(1)
    rows = ExternalEvent.where(plugin: "discord", event_id: "discord:message:#{DISCORD_CHANNEL}/130000000000000010")
             .order(:id).to_a
    expect(rows.size).to eq(2)
    expect(rows.map(&:source_fingerprint).uniq.size).to eq(2)

    Coordination::TriageService.new(ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: sink).call
    expect(Task.count).to eq(1)
    expect(Task.last.task_feedbacks.count).to eq(1)

    transport.assert_consumed!
  end
end

test("discord bot webhook system and plain posts never become tasks") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)

    stub_discord_poll(transport, [
                        discord_event_message("130000000000000009", content: "plain post", mentions: []),
                        discord_event_message("130000000000000008", bot: true, author: DISCORD_BOT_ID),
                        discord_event_message("130000000000000007", webhook: true),
                        discord_event_message("130000000000000006", type: 6, mentions: [])
                      ])
    poll = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(poll.ok).to eq(true)
    expect(poll.ingested).to eq(0)
    expect(ExternalEvent.count).to eq(0)

    result = Coordination::TriageService.new(ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: sink).call
    expect(result.ingested).to eq(0)
    expect(Task.count).to eq(0)
    expect(IntegrationCursor.find_by(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}").cursor)
      .to eq({ "after" => "130000000000000009" })

    transport.assert_consumed!
  end
end

test("admin result batch notifies discord and the reconciler settles delivery") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)

    origin = ExternalEvent.create!(
      plugin: "admin", event_id: "evt-discord-admin", fingerprint: "fp-discord-admin",
      event_type: "admin.task_request", resource_id: "req-discord",
      actor_id: "alice", actor_type: "human", occurred_at: Time.current,
      payload: { "title" => "admin request", "description" => "notify discord" }
    )
    task = Task.create!(title: "admin request", status: "ready",
                        source_plugin: "admin", source_resource_id: "req-discord")
    origin.update!(task: task, processed_at: Time.current)
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

    service = Coordination::ResultService.new(registry: registry, event_sink: sink)
    outcome = service.apply(task_id: task.id, task_version: task.lock_version, feedback_ids: [],
                            policy: policy,
                            result: { "summary" => "Needs review",
                                      "actions" => [{ "plugin" => "discord", "operation" => "send_message",
                                                      "input" => { "scope" => "channel:#{DISCORD_CHANNEL}",
                                                                   "body" => "Please review" } }] })
    expect(outcome.ok).to eq(true)
    expect(task.reload.status).to eq("waiting_delivery")

    transport.expect_json(:POST, DISCORD_POST_URL, body: { "id" => "140000000000000009" })
    ai = WorkflowFakes::FakeAiRunner.new(answers: {})
    delivery = discord_sender(registry, sink, ai).call(task.outbound_actions.last.id)
    expect(delivery.ok).to eq(true)

    settled = Coordination::DeliveryReconciler.new(event_sink: sink).reconcile(task_id: task.id)
    expect(settled.ok).to eq(true)
    expect(task.reload.status).to eq("done")

    transport.assert_consumed!
  end
end

test("disallowed discord destinations fail visibly without side effects") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)
    ai = WorkflowFakes::FakeAiRunner.new(answers: {})

    other = "999000111222333444"
    poll = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{other}")
    expect(poll.ok).to eq(false)
    expect(poll.code).to eq(:scope_not_allowed)
    cursor = IntegrationCursor.find_by(plugin: "discord", scope: "channel/#{other}")
    expect(cursor.last_error.include?("allowlist")).to eq(true)
    expect(ExternalEvent.count).to eq(0)

    forged = OutboundAction.create!(plugin: "discord", operation: "reply",
                                    input: { "resource_id" => "message:#{other}/130000000000000010",
                                             "body" => "forged" },
                                    idempotency_key: SecureRandom.uuid)
    expect(discord_sender(registry, sink, ai).call(forged.id).code).to eq(:scope_not_allowed)
    expect(forged.reload.status).to eq("failed")
    expect(transport.requests).to eq([])

    transport.assert_consumed!
  end
end

test("overlong discord replies fail before any request and never go uncertain") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)
    ai = WorkflowFakes::FakeAiRunner.new(answers: {})

    action = OutboundAction.create!(plugin: "discord", operation: "reply",
                                    input: { "resource_id" => "message:#{DISCORD_CHANNEL}/130000000000000010",
                                             "body" => "x" * 2001 },
                                    idempotency_key: SecureRandom.uuid)
    outcome = discord_sender(registry, sink, ai).call(action.id)
    expect(outcome.ok).to eq(false)
    expect(action.reload.status).to eq("failed")
    expect(transport.requests).to eq([])

    transport.assert_consumed!
  end
end

test("poll uses database-backed account credentials without injection") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)

    account = DiscordAccount.current
    account.bot_token = "db-bot-token"
    account.save!

    stub_discord_poll(transport, [discord_event_message("130000000000000010")])
    poll = Interaction::PollService.new(registry: registry, event_sink: sink)
      .call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(poll.ok).to eq(true)
    expect(poll.ingested).to eq(1)
    auth = transport.requests_to(DISCORD_ME_URL).first[:headers]["Authorization"]
    expect(auth).to eq("Bot db-bot-token")

    transport.assert_consumed!
  end
end

test("failed discord polls retain the saved cursor for retry") do |db:|
  with_workflow_env(scopes: "discord:channel/#{DISCORD_CHANNEL}") do
    sink = WorkflowFakes::FakeEventSink.new
    transport = BoundaryFixtures::HttpTransport.new
    registry = discord_registry(transport)

    stub_discord_poll(transport, [discord_event_message("130000000000000010")])
    first = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(first.ok).to eq(true)

    transport.expect_json(:GET, DISCORD_ME_URL,
                          body: { "id" => DISCORD_BOT_ID, "username" => "aiconshell", "bot" => true })
    transport.expect_json(:GET, DISCORD_LIST_URL, status: 500, body: { "message" => "server error" })
    failed = discord_poller(registry, sink).call(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(failed.ok).to eq(false)
    expect(failed.code).to eq(:plugin_error)
    cursor = IntegrationCursor.find_by(plugin: "discord", scope: "channel/#{DISCORD_CHANNEL}")
    expect(cursor.cursor).to eq({ "after" => "130000000000000010" })
    expect(cursor.last_error.nil?).to eq(false)
    expect(ExternalEvent.count).to eq(1)

    transport.assert_consumed!
  end
end
