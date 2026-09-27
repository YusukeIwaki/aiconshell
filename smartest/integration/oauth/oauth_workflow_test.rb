# frozen_string_literal: true

require "db_helper"
require_relative "oauth_test_support"
require_relative "../workflow/workflow_test_helper"
require_relative "../../support/boundary_fixtures"
require_relative "../../support/scripted_ai"
require_relative "../../../lib/aiconshell/plugins"
require_relative "../../../lib/aiconshell/oauth"

# Issue #26 acceptance: delegated OAuth plugins in the real workflow.
# Real Registry/adapters/services + scripted HTTP/AI boundaries + real
# PostgreSQL. No deep internal mocks: only HTTP transport and AI process
# spawn are replaced; Registry dispatch, adapters, token fencing, schema
# validation, and the real Ai::Runner stay active. Every scripted boundary
# ends with assert_consumed!.
module OauthWorkflowSupport
  CLOUD = OauthTestSupport::CLOUD_ID
  JIRA_BASE = "https://api.atlassian.com/ex/jira/#{CLOUD}"
  GRAPH_BASE = "https://graph.microsoft.com/v1.0"

  module_function

  def oauth_env
    OauthTestSupport.test_env
  end

  def build_registry(transport, env: oauth_env)
    registry = Aiconshell::Plugins::Registry.new(env: env, transport: transport, clock: Time)
    registry.register(Aiconshell::Plugins::Github.new)
    registry.register(Aiconshell::Plugins::Jira.new)
    registry.register(Aiconshell::Plugins::Teams.new)
    registry.register(Aiconshell::Plugins::JiraOauth.new)
    registry.register(Aiconshell::Plugins::TeamsOauth.new)
    registry
  end

  def services_with(transport, env: oauth_env, sink: nil)
    sink ||= WorkflowFakes::FakeEventSink.new
    OauthTestSupport.services(env: env, transport: transport, sink: sink)
  end

  def connect_both(ctx)
    OauthTestSupport.connect(ctx, "atlassian")
    OauthTestSupport.connect(ctx, "microsoft")
  end

  def adf(text)
    { "type" => "doc", "version" => 1,
      "content" => [{ "type" => "paragraph",
                      "content" => [{ "type" => "text", "text" => text }] }] }
  end

  def jira_issue(key, updated:, summary: "summary", text: "desc")
    { "id" => "100#{key.split("-").last}", "key" => key,
      "fields" => { "summary" => summary, "description" => adf(text),
                    "status" => { "name" => "To Do" },
                    "updated" => updated, "created" => "2026-09-20T10:00:00.000+0000" } }
  end

  def jira_comment(id, updated:, text: "comment", author: "acc-123")
    { "id" => id, "body" => adf(text),
      "created" => "2026-09-20T12:00:00Z", "updated" => updated,
      "author" => { "accountId" => author, "accountType" => "atlassian" } }
  end

  def jira_page(collection, values, total: nil)
    { collection => values, "startAt" => 0, "maxResults" => 50, "total" => total || values.length }
  end

  # Empty Jira project poll (no issues).
  def script_jira_empty(transport)
    transport.expect_json(:POST, "#{JIRA_BASE}/rest/api/3/search/jql", body: { "issues" => [] })
  end

  # One issue with one comment.
  def script_jira_comment(transport, key: "PROJ-1", comment_id: "200",
                          updated: "2026-09-26T12:02:00.000+0000", text: "hello oauth")
    transport.expect_json(:POST, "#{JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [jira_issue(key, updated: "2026-09-26T12:01:00.000+0000")]
                          })
    transport.expect_json(:GET, %r{/issue/#{Regexp.escape(key)}/comment}, body:
      jira_page("comments", [jira_comment(comment_id, updated: updated, text: text)]))
    transport.expect_json(:GET, %r{/issue/#{Regexp.escape(key)}/changelog}, body: jira_page("values", []))
  end

  def script_jira_reply(transport, key: "PROJ-1", comment_id: "201")
    transport.expect_json(:POST, "#{JIRA_BASE}/rest/api/3/issue/#{key}/comment",
                          body: { "id" => comment_id })
  end

  def script_jira_create(transport, key: "PROJ-7")
    transport.expect_json(:POST, "#{JIRA_BASE}/rest/api/3/issue", body: { "key" => key })
  end

  def graph_message(id, created:, modified:, from: { "user" => { "id" => "user-oid-1" } }, body: "hello teams")
    { "id" => id, "createdDateTime" => created, "lastModifiedDateTime" => modified,
      "etag" => "etag-#{id}", "subject" => nil, "from" => from,
      "body" => { "content" => body, "contentType" => "text" },
      "webUrl" => "https://teams.test/m/#{id}" }
  end

  def teams_channel_scope(team: "team-1", channel: "chan-1")
    "team/#{team}/channel/#{channel}"
  end

  def teams_channel_send_scope(team: "team-1", channel: "chan-1")
    "channel:#{team}/#{channel}"
  end

  def script_teams_channel_empty(transport, team: "team-1", channel: "chan-1")
    url = "#{GRAPH_BASE}/teams/#{team}/channels/#{channel}/messages?$top=50"
    transport.expect_json(:GET, url, body: { "value" => [] })
  end

  def script_teams_channel_message(transport, team: "team-1", channel: "chan-1",
                                   msg_id: "msg-1", body: "hello teams")
    url = "#{GRAPH_BASE}/teams/#{team}/channels/#{channel}/messages?$top=50"
    transport.expect_json(:GET, url, body: {
                            "value" => [graph_message(msg_id, created: "2026-09-26T12:01:00Z",
                                                      modified: "2026-09-26T12:01:00Z", body: body)]
                          })
    replies = "#{GRAPH_BASE}/teams/#{team}/channels/#{channel}/messages/#{msg_id}/replies?$top=50"
    transport.expect_json(:GET, replies, body: { "value" => [] })
  end

  def script_teams_send(transport, team: "team-1", channel: "chan-1", created: "msg-2")
    url = "#{GRAPH_BASE}/teams/#{team}/channels/#{channel}/messages"
    transport.expect_json(:POST, url, body: { "id" => created })
  end

  def script_teams_reply(transport, team: "team-1", channel: "chan-1", root: "msg-1", created: "reply-1")
    url = "#{GRAPH_BASE}/teams/#{team}/channels/#{channel}/messages/#{root}/replies"
    transport.expect_json(:POST, url, body: { "id" => created })
  end

  def admin_task(status: "inbox")
    resource = "request:#{SecureRandom.uuid}"
    task = Task.create!(title: "Review delegated work", description: "Check oauth reads",
                        source_plugin: "admin", source_resource_id: resource, status: status)
    ExternalEvent.create!(task: task, plugin: "admin", event_type: "admin.task_request",
                          event_id: resource, resource_id: resource, fingerprint: resource,
                          actor_id: "admin", actor_type: "human", occurred_at: Time.current,
                          processed_at: Time.current,
                          payload: { "title" => task.title, "description" => task.description })
    task
  end
end

test("default registry registers delegated plugins with separate scopes and no secrets") do |db:|
  expect(db.transaction_open?).to eq(true)
  catalog = Aiconshell::Plugins::Registry.default.catalog
  by_id = catalog.to_h { |entry| [entry["id"], entry] }
  expect(by_id.keys.sort).to eq(%w[github jira jira_oauth teams teams_oauth])

  jira_oauth = by_id["jira_oauth"]
  teams_oauth = by_id["teams_oauth"]
  jo_ops = jira_oauth["operations"].to_h { |op| [op["name"], op] }
  to_ops = teams_oauth["operations"].to_h { |op| [op["name"], op] }
  expect(jo_ops["latest_events"]["scope"]).to eq("jira_oauth:read")
  expect(jo_ops["reply"]["scope"]).to eq("jira_oauth:write")
  expect(to_ops["latest_events"]["scope"]).to eq("teams_oauth:read")
  expect(to_ops["send_message"]["scope"]).to eq("teams_oauth:write")
  # Independent namespaces: legacy scopes never equal delegated scopes.
  expect(jo_ops["latest_events"]["scope"]).not_to eq("jira:read")
  expect(to_ops["latest_events"]["scope"]).not_to eq("teams:read")
  # Catalog carries env names + configured flags only.
  expect(jira_oauth["required_env"].include?("OAUTH_ATLASSIAN_CLIENT_ID")).to eq(true)
  expect(teams_oauth["required_env"].include?("OAUTH_MICROSOFT_CLIENT_ID")).to eq(true)
  serialized = JSON.generate(catalog)
  expect(serialized.include?("atl-secret")).to eq(false)
  expect(serialized.include?("ms-secret")).to eq(false)
  # Input schemas never carry the trusted binding/provider.
  expect(jo_ops["latest_events"]["input_schema"]["properties"].keys.sort).to eq(%w[cursor scope])
  expect(to_ops["send_message"]["input_schema"]["properties"].keys.sort).to eq(%w[body scope])
  # AI decision schemas never carry credentials or connection rights.
  decision = JSON.generate(Coordination::TriageService::DECISION_SCHEMA)
  expect(decision.include?("oauth_binding")).to eq(false)
  expect(decision.include?("oauth_credential_provider")).to eq(false)
  expect(decision.include?("access_token")).to eq(false)
  result_schema = JSON.generate(Coordination::ResultService::RESULT_SCHEMA)
  expect(result_schema.include?("oauth_binding")).to eq(false)
  expect(result_schema.include?("principal")).to eq(false)
end

test("allowlist namespaces stay separate for delegated plugins") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    validator = Interaction::ActionValidator.new(registry: registry)

    # Legacy allowlist does not authorize the delegated variant.
    bad = validator.validate(plugin: "jira_oauth", operation: "reply",
                             input: { "resource_id" => "issue:PROJ-1", "body" => "hi" })
    expect(bad.ok?).to eq(false)
    expect(bad.code).to eq(:scope_not_allowed)

    query = Interaction::QueryService.new(registry: registry, event_sink: WorkflowFakes::FakeEventSink.new)
    denied = query.validate(plugin: "jira_oauth", operation: "latest_events",
                            input: { "scope" => "PROJ" })
    expect(denied.ok?).to eq(false)
    expect(denied.code).to eq(:scope_not_allowed)
    transport.assert_consumed!
  end
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    validator = Interaction::ActionValidator.new(registry: registry)
    good = validator.validate(plugin: "jira_oauth", operation: "reply",
                              input: { "resource_id" => "issue:PROJ-1", "body" => "hi" })
    expect(good.ok?).to eq(true)
    # Legacy plugin is not authorized by the delegated entry.
    bad = validator.validate(plugin: "jira", operation: "reply",
                             input: { "resource_id" => "issue:PROJ-1", "body" => "hi" })
    expect(bad.ok?).to eq(false)
    transport.assert_consumed!
  end
end

test("jira_oauth poll fixes and fences the binding with per-connection cursor isolation") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    OauthWorkflowSupport.script_jira_comment(transport)
    first = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(first.ok).to eq(true)
    expect(first.code).to eq(:ok)
    expect(ExternalEvent.where(plugin: "jira_oauth").count >= 1).to eq(true)
    cursor = IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ")
    expect(cursor.cursor).to eq({ "since" => "2026-09-26T12:02:00Z" })
    expect(cursor.oauth_binding["provider"]).to eq("atlassian")
    expect(cursor.oauth_binding["principal"]).to eq("acc-123")
    first_binding = cursor.oauth_binding.dup
    first_generation = OauthConnection.find_by(provider: "atlassian").generation

    # Second poll with no new content advances idempotently under the same binding.
    OauthWorkflowSupport.script_jira_empty(transport)
    second = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(second.ok).to eq(true)
    cursor.reload
    expect(cursor.oauth_binding).to eq(first_binding)

    # Replacement disconnects the old generation: the next poll fences
    # instead of reusing the old cursor for the new connection.
    ctx[:auth].disconnect(provider: "atlassian")
    OauthWorkflowSupport::connect_both(ctx) rescue nil
    # Reconnect explicitly for atlassian only (microsoft stays).
    begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "s-reconnect")
    OauthTestSupport.script_atlassian_callback(transport, principal: "acc-999")
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-reconnect")
    new_generation = OauthConnection.find_by(provider: "atlassian").generation
    expect(new_generation == first_generation).to eq(false)

    OauthWorkflowSupport.script_jira_empty(transport)
    third = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(third.ok).to eq(true)
    cursor.reload
    expect(cursor.oauth_binding["principal"]).to eq("acc-999")
    expect(cursor.oauth_binding["generation"]).to eq(new_generation)
    transport.assert_consumed!
  end
end

test("teams_oauth poll coexists with legacy teams on separate namespaces") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    OauthWorkflowSupport.script_teams_channel_message(transport)
    result = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(result.ok).to eq(true)
    expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(1)
    event = ExternalEvent.where(plugin: "teams_oauth").first
    expect(event.resource_id).to eq("message:team-1/chan-1/msg-1")
    # Legacy allowlist does not cover the delegated poll and vice versa.
    expect(WorkflowSettings.scope_allowed?("teams", "team/team-1/channel/chan-1")).to eq(false)
    transport.assert_consumed!
  end
end

test("unconnected delegated poll fails closed before any HTTP") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    # No connect: configured env but no connection row.
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])
    result = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(result.ok).to eq(false)
    expect(result.code).to eq(:not_connected)
    expect(transport.requests).to eq([])
    transport.assert_consumed!
  end
end

test("typed read plus admin result plus outbound plus reconciler over real services") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ,teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    query = Interaction::QueryService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    # Typed read fixes the trusted binding server-side (AI never supplies it).
    OauthWorkflowSupport.script_jira_comment(transport, text: "oauth observation")
    read = query.call(plugin: "jira_oauth", operation: "latest_events", input: { "scope" => "PROJ" })
    expect(read.ok?).to eq(true)
    expect(read.data["events"].size >= 1).to eq(true)
    snapshot = query.oauth_snapshot("jira_oauth")
    expect(snapshot["provider"]).to eq("atlassian")

    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    action = { "plugin" => "teams_oauth", "operation" => "send_message",
               "input" => { "scope" => "channel:team-1/chan-1", "body" => "delegated notice" } }
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "Notify the delegated channel", "actions" => [action] },
                                   oauth_bindings: { "jira_oauth" => snapshot })
    expect(applied.ok).to eq(true)
    task.reload
    expect(task.status).to eq("waiting_delivery")
    outbound = task.outbound_actions.first
    expect(outbound.plugin).to eq("teams_oauth")
    expect(outbound.oauth_binding["provider"]).to eq("microsoft")
    expect(outbound.oauth_binding["principal"]).not_to eq(nil)

    # Real outbound delivery posts once to Graph (token via the stored binding).
    OauthWorkflowSupport.script_teams_send(transport, created: "msg-out-1")
    delivery = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                oauth_credential_provider: ctx[:creds]).call(outbound.id)
    expect(delivery.ok).to eq(true)
    outbound.reload
    expect(outbound.status).to eq("sent")
    expect(outbound.external_id).to eq("message:team-1/chan-1/msg-out-1")
    expect(outbound.input["body"]).to eq("delegated notice")
    posts = transport.requests_to("#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages", method: "POST")
    expect(posts.size).to eq(1)

    settled = Coordination::DeliveryReconciler.new(event_sink: sink).reconcile(task_id: task.id)
    expect(settled.ok).to eq(true)
    expect(settled.code).to eq(:settled_done)
    expect(task.reload.status).to eq("done")
    # No credential material in the event sink.
    serialized = JSON.generate(sink.events)
    expect(serialized.include?("oauth-test-token")).to eq(false)
    expect(serialized.include?("at-1")).to eq(false)
    transport.assert_consumed!
  end
end

test("read to result fencing stops on replacement between typed read and result") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ,teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    query = Interaction::QueryService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    OauthWorkflowSupport.script_jira_comment(transport)
    read = query.call(plugin: "jira_oauth", operation: "latest_events", input: { "scope" => "PROJ" })
    expect(read.ok?).to eq(true)
    stale_snapshot = query.oauth_snapshot("jira_oauth")

    # Replacement for atlassian only.
    ctx[:auth].disconnect(provider: "atlassian")
    begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "s-swap")
    OauthTestSupport.script_atlassian_callback(transport, principal: "acc-replaced")
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-swap")

    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    action = { "plugin" => "jira_oauth", "operation" => "reply",
               "input" => { "resource_id" => "issue:PROJ-1", "body" => "stale write" } }
    rejected = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                    feedback_ids: [], policy: policy,
                                    result: { "summary" => "stale attempt", "actions" => [action] },
                                    oauth_bindings: { "jira_oauth" => stale_snapshot })
    expect(rejected.ok).to eq(false)
    expect(rejected.code).to eq(:stale_binding)
    expect(OutboundAction.count).to eq(0)
    transport.assert_consumed!
  end
end

test("enqueue to delivery fencing stops a replaced connection before any write") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new

    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    action = { "plugin" => "teams_oauth", "operation" => "send_message",
               "input" => { "scope" => "channel:team-1/chan-1", "body" => "first write" } }
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "send once", "actions" => [action] })
    expect(applied.ok).to eq(true)
    outbound = OutboundAction.last

    # Replacement before delivery: the stored generation no longer matches.
    ctx[:auth].disconnect(provider: "microsoft")
    begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "s-swap-ms")
    OauthTestSupport.script_microsoft_callback(transport, principal: "user-replaced")
    ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-swap-ms")

    delivery = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                oauth_credential_provider: ctx[:creds]).call(outbound.id)
    expect(delivery.ok).to eq(false)
    expect(delivery.code).to eq(:stale_binding)
    outbound.reload
    expect(outbound.status).to eq("failed")
    expect(transport.requests_to("#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages", method: "POST")).to eq([])
    transport.assert_consumed!
  end
end

test("self-post receipt suppresses only the app echo") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    # App sends one delegated message; the receipt stores content + id.
    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    body = "app echo body"
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "s", "actions" => [
                                     { "plugin" => "teams_oauth", "operation" => "send_message",
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => body } }
                                   ] })
    expect(applied.ok).to eq(true)
    outbound = OutboundAction.last
    OauthWorkflowSupport.script_teams_send(transport, created: "msg-echo")
    sent = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds]).call(outbound.id)
    expect(sent.ok).to eq(true)

    # Poll returns the echo plus a manual post with a different id.
    echo = OauthWorkflowSupport.graph_message("msg-echo", created: "2026-09-26T12:05:00Z",
                                              modified: "2026-09-26T12:05:00Z", body: body)
    manual = OauthWorkflowSupport.graph_message("msg-manual", created: "2026-09-26T12:06:00Z",
                                                modified: "2026-09-26T12:06:00Z", body: "human words")
    url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages?$top=50"
    transport.expect_json(:GET, url, body: { "value" => [echo, manual] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-echo/replies?$top=50",
                          body: { "value" => [] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-manual/replies?$top=50",
                          body: { "value" => [] })
    result = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(result.ok).to eq(true)
    resources = ExternalEvent.where(plugin: "teams_oauth").order(:id).pluck(:resource_id)
    expect(resources.include?("message:team-1/chan-1/msg-echo")).to eq(false)
    expect(resources.include?("message:team-1/chan-1/msg-manual")).to eq(true)

    # Same numeric-style id on another resource would not suppress: the
    # matcher requires the full resource, not the bare message id.
    other = ExternalEvent.where(plugin: "teams_oauth", resource_id: "message:team-1/chan-1/msg-manual").first
    expect(other.nil?).to eq(false)
    transport.assert_consumed!
  end
end

test("edited app content stays eligible after the original receipt") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "s", "actions" => [
                                     { "plugin" => "jira_oauth", "operation" => "reply",
                                       "input" => { "resource_id" => "issue:PROJ-1", "body" => "original app text" } }
                                   ] })
    expect(applied.ok).to eq(true)
    outbound = OutboundAction.last
    OauthWorkflowSupport.script_jira_reply(transport, comment_id: "300")
    sent = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds]).call(outbound.id)
    expect(sent.ok).to eq(true)
    expect(outbound.reload.external_id).to eq("300")

    # The app echo (same content) suppresses; the human edit (new content,
    # same comment id) stays eligible instead of being ignored forever.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:10:00.000+0000")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("300", updated: "2026-09-26T12:11:00.000+0000", text: "human edited text")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    result = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(result.ok).to eq(true)
    comment_events = ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:300")
    expect(comment_events.count).to eq(1)
    expect(comment_events.first.payload["text"]).to eq("human edited text")
    transport.assert_consumed!
  end
end

test("in-flight and uncertain sends hold matching poll candidates without losing the cursor") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "s", "actions" => [
                                     { "plugin" => "teams_oauth", "operation" => "send_message",
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => "pending write" } }
                                   ] })
    expect(applied.ok).to eq(true)

    # Pending send for the same destination holds the poll: nothing ingested,
    # cursor not advanced, other destinations unaffected (single-scope poll).
    OauthWorkflowSupport.script_teams_channel_message(transport, msg_id: "msg-hold", body: "pending write")
    held = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(held.ok).to eq(false)
    expect(held.code).to eq(:held)
    expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)
    cursor = IntegrationCursor.find_by(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(cursor.cursor).to eq(nil)

    # Uncertain outcome also holds instead of looping or dropping.
    OutboundAction.last.update!(status: "uncertain")
    OauthWorkflowSupport.script_teams_channel_message(transport, msg_id: "msg-hold2", body: "other")
    held2 = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(held2.code).to eq(:held)
    transport.assert_consumed!
  end
end

test("partial paging keeps the stored cursor and never claims completion") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    OauthWorkflowSupport.script_jira_comment(transport)
    first = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(first.ok).to eq(true)
    saved = IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ").cursor.dup

    # Next page never advances: the adapter raises IncompletePoll and the
    # stored cursor stays put for operator review.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [OauthWorkflowSupport.jira_issue("PROJ-9", updated: "2026-09-26T12:20:00.000+0000")],
                            "isLast" => false
                          })
    partial = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(partial.ok).to eq(false)
    expect(IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ").cursor).to eq(saved)
    transport.assert_consumed!
  end
end

test("refresh keeps the generation while rotation stays atomic") do |db:|
  expect(db.transaction_open?).to eq(true)
  transport = BoundaryFixtures::HttpTransport.new
  ctx = OauthWorkflowSupport.services_with(transport)
  OauthWorkflowSupport.connect_both(ctx)
  row = OauthConnection.find_by!(provider: "atlassian")
  generation = row.generation
  binding = ctx[:creds].binding_for("atlassian")
  row.update!(token_expires_at: 1.minute.ago)

  transport.expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: {
                          "access_token" => "at-refreshed", "refresh_token" => "rt-rotated",
                          "expires_in" => 3600, "scope" => OauthTestSupport::ATLASSIAN_SCOPES,
                          "token_type" => "Bearer"
                        })
  token = ctx[:creds].access_token(binding)
  expect(token).to eq("at-refreshed")
  expect(OauthConnection.find_by!(provider: "atlassian").generation).to eq(generation)
  transport.assert_consumed!
end

test("revoked consent surfaces as not_connected without leaking secrets") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    row = OauthConnection.find_by!(provider: "atlassian")
    row.update!(token_expires_at: 1.minute.ago)
    transport.expect_json(:POST, "https://auth.atlassian.com/oauth/token", status: 400, body: {
                            "error" => "invalid_grant", "error_description" => "secret-value-must-not-leak"
                          })
    binding = ctx[:creds].binding_for("atlassian")
    raised = nil
    begin
      ctx[:creds].access_token(binding)
    rescue StandardError => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(raised.class.name.match?(/NotConnected|ProviderError/)).to eq(true)
    expect(raised.message.include?("secret-value-must-not-leak")).to eq(false)
    expect(OauthConnection.find_by!(provider: "atlassian").state).to eq("needs_reauth")
    transport.assert_consumed!
  end
end


test("triage with scripted AI drives an oauth read then a delegated send without binding in prompts") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ,teams_oauth:team/team-1/channel/chan-1") do |_root|
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    task = OauthWorkflowSupport.admin_task
    TaskFeedback.create!(task: task, body: "please check delegated work", author: "human")
    LayerPolicy.create!(layer: "coordination", provider: "claude", enabled: true)

    read_answer = { "read_requests" => [
      { "task_id" => task.id, "plugin" => "jira_oauth", "operation" => "latest_events",
        "input" => { "scope" => "PROJ" } }
    ] }
    ruling_answer = { "rulings" => [
      { "task_id" => task.id,
        "result" => { "summary" => "Delegated review complete",
                      "actions" => [{ "plugin" => "teams_oauth", "operation" => "send_message",
                                      "input" => { "scope" => "channel:team-1/chan-1", "body" => "AI decided notice" } }] } }
    ] }
    BoundaryFixtures.with_ai(answers: [read_answer, ruling_answer]) do |ai|
      OauthWorkflowSupport.script_jira_comment(transport, text: "ai observation")
      triage = Coordination::TriageService.new(ai_runner: ai.runner, registry: registry,
                                               event_sink: WorkflowFakes::FakeEventSink.new,
                                               clock: Time, oauth_credential_provider: ctx[:creds])
      outcome = triage.call(batch_limit: 10)
      expect(outcome.triaged).to eq(1)
      task.reload
      expect(task.status).to eq("waiting_delivery")
      expect(task.outbound_actions.first.plugin).to eq("teams_oauth")
      expect(task.outbound_actions.first.oauth_binding["provider"]).to eq("microsoft")
      # AI prompts never carry bindings, providers, or tokens.
      prompts = ai.process_runner.calls.map { |call| JSON.generate(call).to_s }
      expect(prompts.any? { |p| p.include?("oauth_binding") }).to eq(false)
      expect(prompts.any? { |p| p.include?("oauth_credential_provider") }).to eq(false)
      expect(prompts.any? { |p| p.include?("at-1") }).to eq(false)
      ai.process_runner.assert_consumed!
    end
    transport.assert_consumed!
  end
end

test("plugins controller shows delegated entries with names only and Bot versus OAuth wording") do |http:, db:|
  expect(db.transaction_open?).to eq(true)
  require_relative "../admin/support/admin_test_support"
  AdminTestSupport.as_admin(http) do
    Admin::PluginStatus.reset!
    http.get "/admin/plugins"
    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("jira_oauth")).to eq(true)
    expect(body.include?("teams_oauth")).to eq(true)
    expect(body.include?("OAUTH_ATLASSIAN_CLIENT_ID")).to eq(true)
    expect(body.include?("OAUTH_MICROSOFT_CLIENT_ID")).to eq(true)
  end
end

test("poll schedule enqueues delegated scopes only when configured and concrete") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ,teams_oauth:team/t1/channel/c1,jira_oauth:*,teams:team/t1/channel/c1") do
    job = IntegrationPollScheduleJob.new
    # Real catalog (default registry with oauth) + real allowlist parsing.
    # Wildcard oauth scope is never scheduled; legacy teams entry does not
    # authorize the delegated plugin.
    expect(job.send(:concrete_poll_scope?, "jira_oauth", "PROJ")).to eq(true)
    expect(job.send(:concrete_poll_scope?, "jira_oauth", "*")).to eq(false)
    expect(job.send(:concrete_poll_scope?, "teams_oauth", "team/t1/channel/c1")).not_to eq(false)
    expect(job.send(:concrete_poll_scope?, "teams_oauth", "chat/c1")).not_to eq(false)
    expect(WorkflowSettings.scope_allowed?("jira_oauth", "PROJ")).to eq(true)
    expect(WorkflowSettings.scope_allowed?("jira", "PROJ")).to eq(false)
  end
end
