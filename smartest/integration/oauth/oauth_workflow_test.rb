# frozen_string_literal: true

require "db_helper"
require_relative "oauth_test_support"
require_relative "oauth_admin_support"
require_relative "../admin/support/admin_test_support"
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

  # Single-URL gate in front of a scripted transport: the gated request
  # blocks until the test releases it, so a concurrent poll observes the
  # send while it is really started-but-unconfirmed (status `sending`
  # with `request_started_at` set through the real OutboundService claim
  # path, never a hand-written status).
  class GatedSendTransport
    def initialize(inner, url, entered, release)
      @inner = inner
      @url = url.to_s
      @entered = entered
      @release = release
    end

    def request(method:, url:, headers: {}, body: nil)
      if method.to_s.upcase == "POST" && url.to_s == @url
        @entered << true
        Timeout.timeout(20) { @release.pop }
      end
      @inner.request(method: method, url: url, headers: headers, body: body)
    end
  end

  # Ordered two-phase gate for same-URL requests: the first matching
  # POST parks on the first gate, the second on the second gate. Lets one
  # poll claim a lease and park inside HTTP while a successor poll claims
  # the expired lease and parks behind it.
  class PhasedGateTransport
    def initialize(inner, url, first, second)
      @inner = inner
      @url = url.to_s
      @first = first
      @second = second
      @mutex = Mutex.new
      @count = 0
    end

    def request(method:, url:, headers: {}, body: nil)
      gate = nil
      if method.to_s.upcase == "POST" && url.to_s == @url
        gate = @mutex.synchronize do
          @count += 1
          @count == 1 ? @first : @second
        end
        gate[:entered] << true
        Timeout.timeout(20) { gate[:release].pop }
      end
      @inner.request(method: method, url: url, headers: headers, body: body)
    end
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

test("event task keeps its fetch binding and never replies as a reconnected principal") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])
    gen1 = OauthConnection.find_by(provider: "atlassian").generation
    # The scripted AI boundary only ships a claude executable; the
    # provider name never affects the binding fencing under test.
    LayerPolicy.create!(layer: "coordination", provider: "claude", enabled: true)

    # Poll under the first generation: the event stores the fetch binding.
    OauthWorkflowSupport.script_jira_comment(transport)
    expect(poller.call(plugin: "jira_oauth", scope: "PROJ").ok).to eq(true)
    comment = ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:200")
    expect(comment.nil?).to eq(false)
    expect(comment.oauth_binding["generation"]).to eq(gen1)
    expect(comment.oauth_binding["principal"]).to eq("acc-123")

    # The scripted AI only picks the newest task id; the binding fencing
    # under test stays inside the real TriageService reply path.
    reply_newest = lambda do |_call|
      task = Task.where(source_plugin: "jira_oauth").order(:id).last
      { "rulings" => [{ "task_id" => task.id, "reply" => { "body" => "ack from app" } }] }
    end
    triage_with = lambda do |answer|
      BoundaryFixtures.with_ai(answers: [answer]) do |ai|
        triage = Coordination::TriageService.new(ai_runner: ai.runner, registry: registry,
                                                 event_sink: sink, clock: Time,
                                                 oauth_credential_provider: ctx[:creds])
        outcome = triage.call(batch_limit: 10)
        ai.process_runner.assert_consumed!
        outcome
      end
    end

    first = triage_with.call(reply_newest)
    expect(first.triaged).to eq(1)
    task1 = Task.where(source_plugin: "jira_oauth").order(:id).last
    expect(task1.oauth_binding["generation"]).to eq(gen1)
    expect(task1.outbound_actions.count).to eq(1)
    expect(task1.outbound_actions.first.oauth_binding["generation"]).to eq(gen1)

    # Reconnect as another user. The old Task is due again, but its reply
    # ruling is rejected: no second action, no send as the new principal.
    ctx[:auth].disconnect(provider: "atlassian")
    begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "s-reconnect-reply")
    OauthTestSupport.script_atlassian_callback(transport, principal: "acc-999")
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-reconnect-reply")
    gen2 = OauthConnection.find_by(provider: "atlassian").generation
    expect(gen2 == gen1).to eq(false)

    second = triage_with.call(reply_newest)
    expect(second.triaged).to eq(0)
    expect(second.rejected).to eq(1)
    expect(task1.reload.outbound_actions.count).to eq(1)
    expect(task1.oauth_binding["generation"]).to eq(gen1)

    # A new event under the new generation makes its own Task with its own
    # binding: same-provider Tasks from different generations never mix
    # through one plugin-wide snapshot. Raw IDs stay unchanged; connection
    # scope isolates the rows, so the same comment re-polled under the new
    # generation is a distinct row (old row keeps gen1) with its own Task.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [
                              OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000"),
                              OauthWorkflowSupport.jira_issue("PROJ-2", updated: "2026-09-26T12:05:00.000+0000",
                                                              summary: "second", text: "second desc")
                            ]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("200", updated: "2026-09-26T12:02:00.000+0000", text: "hello oauth")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    transport.expect_json(:GET, %r{/issue/PROJ-2/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("202", updated: "2026-09-26T12:06:00.000+0000", text: "second human")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-2/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    expect(poller.call(plugin: "jira_oauth", scope: "PROJ").ok).to eq(true)
    rows_200 = ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:200").order(:id).to_a
    expect(rows_200.size).to eq(2)
    expect(rows_200.map { |row| row.oauth_binding["generation"] }.sort).to eq([gen1, gen2].sort)
    expect(rows_200.map(&:oauth_source_key).uniq.size).to eq(2)
    expect(rows_200.first.oauth_binding["generation"]).to eq(gen1)
    event2 = ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:202")
    expect(event2.nil?).to eq(false)
    expect(event2.oauth_binding["generation"]).to eq(gen2)

    third = triage_with.call(reply_newest)
    expect(third.triaged).to eq(1)
    task2 = Task.where(source_plugin: "jira_oauth").order(:id).last
    expect(task2.id == task1.id).to eq(false)
    expect(task2.oauth_binding["generation"]).to eq(gen2)
    expect(task2.outbound_actions.count).to eq(1)
    expect(task2.outbound_actions.first.oauth_binding["generation"]).to eq(gen2)
    expect(task1.reload.outbound_actions.count).to eq(1)

    # Deliver the second action for real, then re-poll the same content:
    # nothing duplicates and the stored generations stay put.
    OauthWorkflowSupport.script_jira_reply(transport, key: "PROJ-2", comment_id: "210")
    delivered = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                 oauth_credential_provider: ctx[:creds])
                                                 .call(task2.outbound_actions.first.id)
    expect(delivered.ok).to eq(true)
    expect(task2.outbound_actions.first.reload.external_id).to eq("210")
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [
                              OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000"),
                              OauthWorkflowSupport.jira_issue("PROJ-2", updated: "2026-09-26T12:05:00.000+0000",
                                                              summary: "second", text: "second desc")
                            ]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("200", updated: "2026-09-26T12:02:00.000+0000", text: "hello oauth")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    transport.expect_json(:GET, %r{/issue/PROJ-2/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("202", updated: "2026-09-26T12:06:00.000+0000", text: "second human")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-2/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    expect(poller.call(plugin: "jira_oauth", scope: "PROJ").ok).to eq(true)
    expect(ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:200").count).to eq(2)
    expect(ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:202").count).to eq(1)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:202").oauth_binding["generation"]).to eq(gen2)
    transport.assert_consumed!
  end
end

test("a confirmed self-post still matches past five hundred older receipts") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])

    # One real send for the target destination: HTTP request, receipt,
    # and stored body all go through the production path.
    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "s", "actions" => [
                                     { "plugin" => "teams_oauth", "operation" => "send_message",
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => "target echo body" } }
                                   ] })
    expect(applied.ok).to eq(true)
    outbound = OutboundAction.last

    # 501 older confirmed receipts for another destination are stored
    # first, so the target receipt below is the newest sent row: any row
    # cap (the old limit(500)) cuts the target off before
    # binding/resource matching ever sees it.
    old_rows = (1..501).map do |i|
      { plugin: "teams_oauth", operation: "send_message",
        input: { "scope" => "channel:team-1/chan-9", "body" => "old body #{i}" },
        idempotency_key: "old-receipt-#{i}", status: "sent",
        external_id: "message:team-1/chan-9/old-#{i}",
        oauth_binding: outbound.oauth_binding }
    end
    OutboundAction.insert_all(old_rows)

    OauthWorkflowSupport.script_teams_send(transport, created: "msg-target")
    sent = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds]).call(outbound.id)
    expect(sent.ok).to eq(true)

    echo = OauthWorkflowSupport.graph_message("msg-target", created: "2026-09-26T12:05:00Z",
                                              modified: "2026-09-26T12:05:00Z", body: "target echo body")
    manual = OauthWorkflowSupport.graph_message("msg-manual-501", created: "2026-09-26T12:06:00Z",
                                                modified: "2026-09-26T12:06:00Z", body: "human words")
    url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages?$top=50"
    transport.expect_json(:GET, url, body: { "value" => [echo, manual] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-target/replies?$top=50",
                          body: { "value" => [] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-manual-501/replies?$top=50",
                          body: { "value" => [] })
    result = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(result.ok).to eq(true)
    resources = ExternalEvent.where(plugin: "teams_oauth").order(:id).pluck(:resource_id)
    expect(resources.include?("message:team-1/chan-1/msg-target")).to eq(false)
    expect(resources.include?("message:team-1/chan-1/msg-manual-501")).to eq(true)
    transport.assert_consumed!
  end
end

test("the same numeric comment id on another jira issue is never suppressed") do |db:|
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
                                       "input" => { "resource_id" => "issue:PROJ-1", "body" => "shared text" } }
                                   ] })
    expect(applied.ok).to eq(true)
    OauthWorkflowSupport.script_jira_reply(transport, key: "PROJ-1", comment_id: "300")
    sent = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds]).call(OutboundAction.last.id)
    expect(sent.ok).to eq(true)

    # Same numeric id 300 with the same body, but on another issue and at
    # a different instant (so the rows are independently storable): only
    # the true echo is suppressed.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [
                              OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:10:00.000+0000"),
                              OauthWorkflowSupport.jira_issue("PROJ-2", updated: "2026-09-26T12:10:00.000+0000",
                                                              summary: "other", text: "other desc")
                            ]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("300", updated: "2026-09-26T12:11:00.000+0000", text: "shared text")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    transport.expect_json(:GET, %r{/issue/PROJ-2/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("300", updated: "2026-09-26T12:12:00.000+0000", text: "shared text")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-2/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    result = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(result.ok).to eq(true)
    same_id = ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:300")
    expect(same_id.count).to eq(1)
    expect(same_id.first.resource_id).to eq("issue:PROJ-2")
    expect(same_id.first.payload["text"]).to eq("shared text")
    transport.assert_consumed!
  end
end

test("the same numeric message id on another teams resource is never suppressed") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1,teams_oauth:chat/chat-9") do
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
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => "shared digits body" } }
                                   ] })
    expect(applied.ok).to eq(true)
    OauthWorkflowSupport.script_teams_send(transport, created: "700")
    sent = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds]).call(OutboundAction.last.id)
    expect(sent.ok).to eq(true)
    expect(OutboundAction.last.reload.external_id).to eq("message:team-1/chan-1/700")

    # Same trailing numeric id with the same body, but a chat message
    # instead of the channel message: the full resource differs, so the
    # candidate stays eligible.
    other = OauthWorkflowSupport.graph_message("700", created: "2026-09-26T12:07:00Z",
                                               modified: "2026-09-26T12:07:00Z", body: "shared digits body")
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/chats/chat-9/messages?$top=50",
                          body: { "value" => [other] })
    result = poller.call(plugin: "teams_oauth", scope: "chat/chat-9")
    expect(result.ok).to eq(true)
    row = ExternalEvent.find_by(plugin: "teams_oauth", resource_id: "chat_message:chat-9/700")
    expect(row.nil?).to eq(false)
    expect(row.payload["content"]).to eq("shared digits body")
    transport.assert_consumed!
  end
end

test("a pending jira reply holds only its own issue") do |db:|
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
                                       "input" => { "resource_id" => "issue:PROJ-1", "body" => "held reply" } }
                                   ] })
    expect(applied.ok).to eq(true)

    # Another issue in the same project is unaffected by the pending
    # reply: it ingests normally and advances the cursor.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [OauthWorkflowSupport.jira_issue("PROJ-2", updated: "2026-09-26T12:20:00.000+0000",
                                                                         summary: "other", text: "other desc")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-2/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("910", updated: "2026-09-26T12:21:00.000+0000", text: "other issue words")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-2/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    other = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(other.ok).to eq(true)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:910").nil?).to eq(false)
    saved_cursor = IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ").cursor.dup

    # The reply's own issue is held instead: nothing ingested, cursor retained.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:22:00.000+0000")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("911", updated: "2026-09-26T12:23:00.000+0000", text: "same issue words")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    held = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(held.ok).to eq(false)
    expect(held.code).to eq(:held)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:911").nil?).to eq(true)
    expect(IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ").cursor).to eq(saved_cursor)
    transport.assert_consumed!
  end
end

test("a real transport timeout becomes uncertain and holds only its destination") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1,teams_oauth:team/team-1/channel/chan-2") do
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
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => "timeout write" } }
                                   ] })
    expect(applied.ok).to eq(true)
    outbound = OutboundAction.last

    # The write really starts (claim + request_started_at commit) and the
    # transport really times out: outcome unknown, never auto-resent.
    send_url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
    transport.expect_error(:POST, send_url,
                           Aiconshell::Plugins::TransportTimeout.new(http_method: "POST", url: send_url,
                                                                    timeout_kind: "read"))
    delivery = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                oauth_credential_provider: ctx[:creds]).call(outbound.id)
    expect(delivery.ok).to eq(false)
    expect(delivery.code).to eq(:delivery_uncertain)
    expect(outbound.reload.status).to eq("uncertain")
    expect(outbound.request_started_at.nil?).to eq(false)

    # The uncertain destination is held without losing the cursor...
    OauthWorkflowSupport.script_teams_channel_message(transport, msg_id: "msg-uncertain", body: "timeout write")
    held = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(held.ok).to eq(false)
    expect(held.code).to eq(:held)
    expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)
    expect(IntegrationCursor.find_by(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1").cursor).to eq(nil)

    # ...while another destination on the same connection still processes.
    OauthWorkflowSupport.script_teams_channel_message(transport, team: "team-1", channel: "chan-2",
                                                      msg_id: "msg-other", body: "other channel words")
    other = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-2")
    expect(other.ok).to eq(true)
    expect(ExternalEvent.find_by(plugin: "teams_oauth",
                                 resource_id: "message:team-1/chan-2/msg-other").nil?).to eq(false)
    transport.assert_consumed!
  end
end

test("an AI-drafted body ties the receipt to what was actually sent") do |db:|
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
    LayerPolicy.create!(layer: "interaction", provider: "claude", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "s", "actions" => [
                                     { "plugin" => "teams_oauth", "operation" => "send_message",
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => "original notice" } }
                                   ] })
    expect(applied.ok).to eq(true)
    outbound = OutboundAction.last

    # Interaction drafting really rewrites the body on the send path.
    BoundaryFixtures.with_ai(answers: [{ "body" => "drafted notice" }]) do |ai|
      OauthWorkflowSupport.script_teams_send(transport, created: "msg-draft")
      delivery = Interaction::OutboundService.new(registry: registry, ai_runner: ai.runner, event_sink: sink,
                                                  oauth_credential_provider: ctx[:creds]).call(outbound.id)
      expect(delivery.ok).to eq(true)
      ai.process_runner.assert_consumed!
    end
    post = transport.requests_to("#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages",
                                 method: "POST").first
    expect(JSON.parse(post[:body]).dig("body", "content")).to eq("drafted notice")
    expect(outbound.reload.input["body"]).to eq("drafted notice")

    # Only the echo with the actually sent body is suppressed; the same
    # id carrying the pre-draft body (a human edit) stays eligible.
    echo = OauthWorkflowSupport.graph_message("msg-draft", created: "2026-09-26T12:30:00Z",
                                              modified: "2026-09-26T12:30:00Z", body: "drafted notice")
    url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages?$top=50"
    transport.expect_json(:GET, url, body: { "value" => [echo] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-draft/replies?$top=50",
                          body: { "value" => [] })
    expect(poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1").ok).to eq(true)
    expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)

    edited = OauthWorkflowSupport.graph_message("msg-draft", created: "2026-09-26T12:30:00Z",
                                                modified: "2026-09-26T12:31:00Z", body: "original notice")
    transport.expect_json(:GET, url, body: { "value" => [edited] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-draft/replies?$top=50",
                          body: { "value" => [] })
    expect(poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1").ok).to eq(true)
    revision = ExternalEvent.where(plugin: "teams_oauth",
                                   resource_id: "message:team-1/chan-1/msg-draft")
    expect(revision.count).to eq(1)
    expect(revision.first.payload["content"]).to eq("original notice")
    transport.assert_consumed!
  end
end

test("a pre-reconnect app post is still recognized as self echo after reconnect") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])
    gen1 = OauthConnection.find_by(provider: "microsoft").generation

    task = OauthWorkflowSupport.admin_task
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])
    applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                   feedback_ids: [], policy: policy,
                                   result: { "summary" => "s", "actions" => [
                                     { "plugin" => "teams_oauth", "operation" => "send_message",
                                       "input" => { "scope" => "channel:team-1/chan-1", "body" => "reconnect echo body" } }
                                   ] })
    expect(applied.ok).to eq(true)
    OauthWorkflowSupport.script_teams_send(transport, created: "msg-reconnect")
    sent = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds]).call(OutboundAction.last.id)
    expect(sent.ok).to eq(true)

    # Reconnect (even as another principal in the same tenant): the cursor
    # resets and the old post is re-fetched, but receipt identity is
    # generation-independent so the echo is still recognized.
    ctx[:auth].disconnect(provider: "microsoft")
    begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "s-reconnect-echo")
    OauthTestSupport.script_microsoft_callback(transport, principal: "user-oid-2")
    ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-reconnect-echo")
    gen2 = OauthConnection.find_by(provider: "microsoft").generation
    expect(gen2 == gen1).to eq(false)

    echo = OauthWorkflowSupport.graph_message("msg-reconnect", created: "2026-09-26T12:40:00Z",
                                              modified: "2026-09-26T12:40:00Z", body: "reconnect echo body")
    url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages?$top=50"
    transport.expect_json(:GET, url, body: { "value" => [echo] })
    transport.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-reconnect/replies?$top=50",
                          body: { "value" => [] })
    result = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(result.ok).to eq(true)
    expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)
    cursor = IntegrationCursor.find_by(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(cursor.oauth_binding["generation"]).to eq(gen2)
    transport.assert_consumed!
  end
end

test("a poll during a blocked delegated send holds without losing the cursor") do
  # No db: fixture on purpose: rows commit so the delivery thread and the
  # poller observe each other on independent connections (the same shape
  # as the foundation race tests). Everything created here is deleted in
  # ensure; other tests roll back and never see these rows.
  owned = { tasks: [], actions: [], events: [], cursors: [], policies: [] }
  entered = Queue.new
  release = Queue.new
  delivery_result = Queue.new
  worker = nil
  begin
    OauthConnection.delete_all
    OauthAuthAttempt.delete_all
    with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1") do
      inner = BoundaryFixtures::HttpTransport.new
      ctx = OauthWorkflowSupport.services_with(inner)
      OauthWorkflowSupport.connect_both(ctx)
      send_url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
      gated = OauthWorkflowSupport::GatedSendTransport.new(inner, send_url, entered, release)
      registry = OauthWorkflowSupport.build_registry(gated)
      sink = WorkflowFakes::FakeEventSink.new
      poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds])

      task = OauthWorkflowSupport.admin_task
      owned[:tasks] << task.id
      owned[:events].concat(task.external_events.pluck(:id))
      policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
      owned[:policies] << policy.id
      result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                       clock: Time, oauth_credential_provider: ctx[:creds])
      applied = result_service.apply(task_id: task.id, task_version: task.lock_version,
                                     feedback_ids: [], policy: policy,
                                     result: { "summary" => "s", "actions" => [
                                       { "plugin" => "teams_oauth", "operation" => "send_message",
                                         "input" => { "scope" => "channel:team-1/chan-1", "body" => "blocked write" } }
                                     ] })
      expect(applied.ok).to eq(true)
      action = OutboundAction.last
      owned[:actions] << action.id
      OauthWorkflowSupport.script_teams_send(inner, created: "msg-blocked")

      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            service = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                       oauth_credential_provider: ctx[:creds])
            delivery_result << { ok: true, result: service.call(action.id) }
          rescue StandardError => e
            delivery_result << { ok: false, error: e }
          end
        end
      end
      # The send HTTP really started: the claim and request_started_at are
      # committed and visible here while the remote reply is still gated.
      Timeout.timeout(15) { entered.pop }
      sending = OutboundAction.find(action.id)
      expect(sending.status).to eq("sending")
      expect(sending.request_started_at.nil?).to eq(false)

      # The concurrent poll observes the started-but-unconfirmed send and
      # holds the whole batch instead of ingesting it or advancing past it.
      OauthWorkflowSupport.script_teams_channel_message(inner, msg_id: "msg-blocked-candidate",
                                                        body: "blocked write")
      held = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
      expect(held.ok).to eq(false)
      expect(held.code).to eq(:held)
      expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)
      cursor = IntegrationCursor.find_by(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
      owned[:cursors] << cursor.id
      expect(cursor.cursor).to eq(nil)

      # Release the send: it completes, the receipt lands, and the echo
      # suppresses on re-poll instead of looping.
      release << true
      outcome = Timeout.timeout(20) { delivery_result.pop }
      Timeout.timeout(20) { worker.join(20) || raise("delivery thread stuck") }
      worker = nil
      expect(outcome[:ok]).to eq(true)
      expect(outcome[:result].ok).to eq(true)
      expect(OutboundAction.find(action.id).status).to eq("sent")

      echo = OauthWorkflowSupport.graph_message("msg-blocked", created: "2026-09-26T12:50:00Z",
                                                modified: "2026-09-26T12:50:00Z", body: "blocked write")
      url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages?$top=50"
      inner.expect_json(:GET, url, body: { "value" => [echo] })
      inner.expect_json(:GET, "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages/msg-blocked/replies?$top=50",
                        body: { "value" => [] })
      repolled = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
      expect(repolled.ok).to eq(true)
      expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)
      inner.assert_consumed!
    end
  ensure
    begin
      release << true
    rescue StandardError
      nil
    end
    if worker.is_a?(Thread)
      begin
        Timeout.timeout(20) { worker.join(20) }
      rescue StandardError
        nil
      end
    end
    OutboundAction.where(id: owned[:actions]).delete_all
    ExternalEvent.where(id: owned[:events]).delete_all
    ExternalEvent.where(plugin: %w[jira_oauth teams_oauth]).delete_all
    IntegrationCursor.where(id: owned[:cursors]).delete_all
    Task.where(id: owned[:tasks]).delete_all
    LayerPolicy.where(id: owned[:policies]).delete_all
    OauthConnection.delete_all
    OauthAuthAttempt.delete_all
  end
end

test("a stale poll releases only its own cursor lease") do
  # No db: fixture on purpose (threads + real commits, cleaned in
  # ensure). The first poll claims a 1-second lease and parks inside
  # HTTP; the lease lapses, the connection is replaced, and a successor
  # poll claims the cursor and parks behind it. When the first poll is
  # released it must report stale_binding while leaving the successor's
  # active lease alone; the old code cleared whatever lease it found.
  owned = { cursors: [] }
  old_poll_lease = ENV["AICONSHELL_POLL_LEASE_SECONDS"]
  ENV["AICONSHELL_POLL_LEASE_SECONDS"] = "2"
  first_entered = Queue.new
  first_release = Queue.new
  second_entered = Queue.new
  second_release = Queue.new
  first_result = Queue.new
  second_result = Queue.new
  first_worker = nil
  second_worker = nil
  begin
    OauthConnection.delete_all
    OauthAuthAttempt.delete_all
    with_workflow_env(scopes: "jira_oauth:PROJ") do
      inner = BoundaryFixtures::HttpTransport.new
      ctx = OauthWorkflowSupport.services_with(inner)
      OauthWorkflowSupport.connect_both(ctx)
      gen1 = OauthConnection.find_by(provider: "atlassian").generation
      search_url = "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql"
      gated = OauthWorkflowSupport::PhasedGateTransport.new(
        inner, search_url,
        { entered: first_entered, release: first_release },
        { entered: second_entered, release: second_release }
      )
      registry = OauthWorkflowSupport.build_registry(gated)
      sink = WorkflowFakes::FakeEventSink.new
      poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds])
      poll_in_thread = lambda do |queue|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            begin
              queue << { ok: true, result: poller.call(plugin: "jira_oauth", scope: "PROJ") }
            rescue StandardError => e
              queue << { ok: false, error: e }
            end
          end
        end
      end

      OauthWorkflowSupport.script_jira_comment(inner)
      first_worker = poll_in_thread.call(first_result)
      Timeout.timeout(15) { first_entered.pop }

      # The first lease lapses while parked; the connection is replaced
      # and the successor claims the cursor with the new binding.
      sleep 2.2
      ctx[:auth].disconnect(provider: "atlassian")
      begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "s-stale-lease")
      OauthTestSupport.script_atlassian_callback(inner, principal: "acc-999")
      ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                          code: "auth-code-1", browser_session_id: "s-stale-lease")
      gen2 = OauthConnection.find_by(provider: "atlassian").generation
      expect(gen2 == gen1).to eq(false)
      OauthWorkflowSupport.script_jira_comment(inner)
      second_worker = poll_in_thread.call(second_result)
      Timeout.timeout(15) { second_entered.pop }
      cursor = IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ")
      owned[:cursors] << cursor.id
      expect(cursor.lease_active?(Time.current)).to eq(true)

      # Release the stale poll first: it reports stale_binding and must
      # not touch the successor's active lease.
      first_release << true
      first_outcome = Timeout.timeout(20) { first_result.pop }
      Timeout.timeout(20) { first_worker.join(20) || raise("first poll stuck") }
      first_worker = nil
      expect(first_outcome[:ok]).to eq(true)
      expect(first_outcome[:result].code).to eq(:stale_binding)
      expect(IntegrationCursor.find(cursor.id).lease_active?(Time.current)).to eq(true)

      # The successor then commits normally under the new binding.
      second_release << true
      second_outcome = Timeout.timeout(20) { second_result.pop }
      Timeout.timeout(20) { second_worker.join(20) || raise("second poll stuck") }
      second_worker = nil
      expect(second_outcome[:ok]).to eq(true)
      expect(second_outcome[:result].ok).to eq(true)
      cursor.reload
      expect(cursor.oauth_binding["generation"]).to eq(gen2)
      expect(cursor.lease_token.nil?).to eq(true)
      expect(ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:200").count).to eq(1)
      inner.assert_consumed!
    end
  ensure
    ENV["AICONSHELL_POLL_LEASE_SECONDS"] = old_poll_lease
    begin
      first_release << true
    rescue StandardError
      nil
    end
    begin
      second_release << true
    rescue StandardError
      nil
    end
    [first_worker, second_worker].each do |thread|
      next unless thread.is_a?(Thread)

      begin
        Timeout.timeout(20) { thread.join(20) }
      rescue StandardError
        nil
      end
    end
    ExternalEvent.where(plugin: %w[jira_oauth teams_oauth]).delete_all
    IntegrationCursor.where(id: owned[:cursors]).delete_all
    OauthConnection.delete_all
    OauthAuthAttempt.delete_all
  end
end

test("a stale poll clears its own lease without advancing the cursor") do
  # No db: fixture on purpose (threads + real commits, cleaned in
  # ensure). The poll claims its lease and parks inside HTTP; the
  # connection is replaced while parked. On release the poll reports
  # stale_binding, clears the lease it claimed, and leaves the stored
  # cursor and binding untouched. The old branch never released anything
  # (with_lock yields no record, so the update raised into rescue nil)
  # and leaked the lease until expiry.
  owned = { cursors: [] }
  entered = Queue.new
  release = Queue.new
  poll_result = Queue.new
  worker = nil
  begin
    OauthConnection.delete_all
    OauthAuthAttempt.delete_all
    with_workflow_env(scopes: "jira_oauth:PROJ") do
      inner = BoundaryFixtures::HttpTransport.new
      ctx = OauthWorkflowSupport.services_with(inner)
      OauthWorkflowSupport.connect_both(ctx)
      search_url = "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql"
      gated = OauthWorkflowSupport::GatedSendTransport.new(inner, search_url, entered, release)
      registry = OauthWorkflowSupport.build_registry(gated)
      sink = WorkflowFakes::FakeEventSink.new
      poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                            oauth_credential_provider: ctx[:creds])

      OauthWorkflowSupport.script_jira_comment(inner)
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            poll_result << { ok: true, result: poller.call(plugin: "jira_oauth", scope: "PROJ") }
          rescue StandardError => e
            poll_result << { ok: false, error: e }
          end
        end
      end
      Timeout.timeout(15) { entered.pop }
      cursor = IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ")
      owned[:cursors] << cursor.id
      expect(cursor.lease_active?(Time.current)).to eq(true)

      ctx[:auth].disconnect(provider: "atlassian")
      begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "s-stale-own")
      OauthTestSupport.script_atlassian_callback(inner, principal: "acc-999")
      ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                          code: "auth-code-1", browser_session_id: "s-stale-own")

      release << true
      outcome = Timeout.timeout(20) { poll_result.pop }
      Timeout.timeout(20) { worker.join(20) || raise("stale poll stuck") }
      worker = nil
      expect(outcome[:ok]).to eq(true)
      expect(outcome[:result].ok).to eq(false)
      expect(outcome[:result].code).to eq(:stale_binding)
      cursor.reload
      expect(cursor.lease_token.nil?).to eq(true)
      expect(cursor.lease_expires_at.nil?).to eq(true)
      # Nothing committed: no events, no cursor value, no binding yet.
      expect(cursor.oauth_binding.nil?).to eq(true)
      expect(cursor.cursor.nil?).to eq(true)
      expect(ExternalEvent.where(plugin: "jira_oauth").count).to eq(0)

      # The freed cursor is immediately claimable again; the next poll
      # restarts from no cursor under the new binding (through an
      # ungated registry: the gate above belonged to the stale poll).
      OauthWorkflowSupport.script_jira_empty(inner)
      poller2 = Interaction::PollService.new(
        registry: OauthWorkflowSupport.build_registry(inner), event_sink: sink,
        oauth_credential_provider: ctx[:creds])
      second = poller2.call(plugin: "jira_oauth", scope: "PROJ")
      expect(second.ok).to eq(true)
      expect(second.code).to eq(:ok)
      expect(cursor.reload.oauth_binding["principal"]).to eq("acc-999")
      inner.assert_consumed!
    end
  ensure
    begin
      release << true
    rescue StandardError
      nil
    end
    if worker.is_a?(Thread)
      begin
        Timeout.timeout(20) { worker.join(20) }
      rescue StandardError
        nil
      end
    end
    ExternalEvent.where(plugin: %w[jira_oauth teams_oauth]).delete_all
    IntegrationCursor.where(id: owned[:cursors]).delete_all
    OauthConnection.delete_all
    OauthAuthAttempt.delete_all
  end
end

test("oauth management controller connect drives the delegated workflow end to end") do |http:|
  AdminTestSupport.with_env(AdminTestSupport::USERNAME, AdminTestSupport::PASSWORD) do
    OauthAdminSupport.with_service do |ctx|
      http.header "Host", AdminTestSupport::HOST
      http.header "User-Agent", AdminTestSupport::MODERN_UA
      http.basic_authorize AdminTestSupport::USERNAME, AdminTestSupport::PASSWORD

      # Both providers connect through the real #23 controllers: admin
      # begin POST, fixed provider authorize redirect, public callback.
      { "atlassian" => "https://auth.atlassian.com/authorize?",
        "microsoft" => "https://login.microsoftonline.com/test-tenant/oauth2/v2.0/authorize?" }.each do |provider, prefix|
        http.post "/admin/oauth_connections/connect", { provider: provider }
        expect(http.last_response.status).to eq(302)
        location = http.last_response.headers["Location"]
        expect(location.start_with?(prefix)).to eq(true)
        state = OauthAdminSupport.state_from_location(location)
        if provider == "atlassian"
          OauthTestSupport.script_atlassian_callback(ctx[:transport])
        else
          OauthTestSupport.script_microsoft_callback(ctx[:transport])
        end
        http.get "/oauth/#{provider}/callback", { state: state, code: "auth-code-1" }
        expect(http.last_response.status).to eq(302)
        http.follow_redirect!
        expect(http.last_response.status).to eq(200)
        expect(http.last_response.body.include?("接続済み")).to eq(true)
      end
      expect(OauthConnection.find_by(provider: "atlassian").external_principal).to eq("acc-123")
      expect(OauthConnection.find_by(provider: "microsoft").external_principal).to eq("user-oid-1")

      # The workflow side uses fresh service instances over the same
      # secret store, env, and scripted HTTP boundary: the
      # controller-established connections resolve into real tokens,
      # polls, reads, sends, and reconciliation with nothing stubbed.
      sink = WorkflowFakes::FakeEventSink.new
      fresh_creds = Oauth::CredentialProvider.new(env: ctx[:env], transport: ctx[:transport], clock: Time,
                                                  secret_store: ctx[:store], event_sink: sink)
      registry = OauthWorkflowSupport.build_registry(ctx[:transport], env: ctx[:env])
      with_workflow_env(scopes: "jira_oauth:PROJ,teams_oauth:team/team-1/channel/chan-1") do
        poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                              oauth_credential_provider: fresh_creds)
        OauthWorkflowSupport.script_jira_comment(ctx[:transport])
        polled = poller.call(plugin: "jira_oauth", scope: "PROJ")
        expect(polled.ok).to eq(true)
        event = ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:200")
        expect(event.oauth_binding["principal"]).to eq("acc-123")

        query = Interaction::QueryService.new(registry: registry, event_sink: sink,
                                              oauth_credential_provider: fresh_creds)
        OauthWorkflowSupport.script_jira_comment(ctx[:transport], text: "controller observation")
        read = query.call(plugin: "jira_oauth", operation: "latest_events", input: { "scope" => "PROJ" })
        expect(read.ok?).to eq(true)

        task = OauthWorkflowSupport.admin_task
        policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
        result_service = Coordination::ResultService.new(registry: registry, event_sink: sink, clock: Time,
                                                         oauth_credential_provider: fresh_creds)
        applied = result_service.apply(task_id: task.id, task_version: task.lock_version, feedback_ids: [],
                                       policy: policy,
                                       result: { "summary" => "Controller roundtrip complete", "actions" => [
                                         { "plugin" => "teams_oauth", "operation" => "send_message",
                                           "input" => { "scope" => "channel:team-1/chan-1",
                                                        "body" => "controller roundtrip notice" } }
                                       ] })
        expect(applied.ok).to eq(true)
        outbound = task.outbound_actions.first
        expect(outbound.oauth_binding["principal"]).to eq("user-oid-1")

        OauthWorkflowSupport.script_teams_send(ctx[:transport], created: "msg-roundtrip")
        delivery = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                    oauth_credential_provider: fresh_creds).call(outbound.id)
        expect(delivery.ok).to eq(true)
        expect(outbound.reload.external_id).to eq("message:team-1/chan-1/msg-roundtrip")

        settled = Coordination::DeliveryReconciler.new(event_sink: sink).reconcile(task_id: task.id)
        expect(settled.ok).to eq(true)
        expect(task.reload.status).to eq("done")

        serialized = JSON.generate(sink.events)
        expect(serialized.include?("at-1")).to eq(false)
        expect(serialized.include?("ms-at-1")).to eq(false)
        expect(serialized.include?("auth-code-1")).to eq(false)
      end
      ctx[:transport].assert_consumed!
    end
  end
end

test("receipt scope ignores generation but never crosses cloud or tenant") do |db:|
  expect(db.transaction_open?).to eq(true)
  binding = { "connection_id" => 1, "generation" => 1, "provider" => "atlassian",
              "principal" => "acc-1", "tenant" => nil, "cloud" => "cloud-1" }
  action = OutboundAction.new(plugin: "jira_oauth", operation: "reply",
                              input: { "resource_id" => "issue:PROJ-1", "body" => "x" },
                              idempotency_key: "scope-check", status: "sent",
                              external_id: "9", oauth_binding: binding)
  moved = binding.merge("generation" => 2, "connection_id" => 7, "principal" => "acc-2")
  expect(Interaction::SelfPostMatcher.receipt_scope_matches?(action, moved)).to eq(true)
  expect(Interaction::SelfPostMatcher.receipt_scope_matches?(action, moved.merge("cloud" => "cloud-2"))).to eq(false)
  expect(Interaction::SelfPostMatcher.receipt_scope_matches?(action, moved.merge("provider" => "microsoft"))).to eq(false)
  unscoped = OutboundAction.new(plugin: "jira_oauth", operation: "reply", input: {},
                                idempotency_key: "scope-check-2", status: "sent")
  expect(Interaction::SelfPostMatcher.receipt_scope_matches?(unscoped, moved)).to eq(false)
  expect(Interaction::SelfPostMatcher.receipt_scope_matches?(action, nil)).to eq(false)
end

test("same event and resource IDs across connections stay isolated with no partial stale reply") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])
    gen1 = OauthConnection.find_by(provider: "atlassian").generation
    LayerPolicy.create!(layer: "coordination", provider: "claude", enabled: true)
    LayerPolicy.create!(layer: "execution", provider: "codex", enabled: true)

    # Same raw provider IDs under the first generation.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("600", updated: "2026-09-26T12:02:00.000+0000", text: "same ids human")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    expect(poller.call(plugin: "jira_oauth", scope: "PROJ").ok).to eq(true)
    event1 = ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:600")
    expect(event1.nil?).to eq(false)
    expect(event1.resource_id).to eq("issue:PROJ-1")
    expect(event1.oauth_binding["generation"]).to eq(gen1)

    triage_newest = lambda do |answer|
      BoundaryFixtures.with_ai(answers: [answer]) do |ai|
        triage = Coordination::TriageService.new(ai_runner: ai.runner, registry: registry,
                                                 event_sink: sink, clock: Time,
                                                 oauth_credential_provider: ctx[:creds])
        outcome = triage.call(batch_limit: 10)
        ai.process_runner.assert_consumed!
        outcome
      end
    end
    newest_id = lambda { Task.where(source_plugin: "jira_oauth").order(:id).last.id }
    first = triage_newest.call(lambda do |_call|
      { "rulings" => [{ "task_id" => newest_id.call, "reply" => { "body" => "ack gen1" } }] }
    end)
    expect(first.triaged).to eq(1)
    task1 = Task.where(source_plugin: "jira_oauth").order(:id).last
    expect(task1.source_resource_id).to eq("issue:PROJ-1")
    expect(task1.oauth_binding["generation"]).to eq(gen1)
    key1 = task1.oauth_source_key
    expect(key1.nil?).to eq(false)
    expect(task1.outbound_actions.count).to eq(1)

    # Reconnect as another principal: same cloud, new generation.
    ctx[:auth].disconnect(provider: "atlassian")
    begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "s-same-ids")
    OauthTestSupport.script_atlassian_callback(transport, principal: "acc-999")
    ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-same-ids")
    gen2 = OauthConnection.find_by(provider: "atlassian").generation
    expect(gen2 == gen1).to eq(false)

    # The SAME raw event/resource IDs re-polled under the new connection
    # are a distinct isolated row, never merged into the old Task.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("600", updated: "2026-09-26T12:02:00.000+0000", text: "same ids human")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    expect(poller.call(plugin: "jira_oauth", scope: "PROJ").ok).to eq(true)
    rows = ExternalEvent.where(plugin: "jira_oauth", event_id: "jira:comment:600").order(:id).to_a
    expect(rows.size).to eq(2)
    expect(rows.map { |row| row.oauth_binding["generation"] }.sort).to eq([gen1, gen2].sort)
    expect(rows.map(&:oauth_source_key).uniq.size).to eq(2)
    expect(rows.map(&:resource_id).uniq).to eq(["issue:PROJ-1"])

    # Ingest without replying: the new row must create its own Task.
    BoundaryFixtures.with_ai(answers: [{ "rulings" => [] }]) do |ai|
      triage = Coordination::TriageService.new(ai_runner: ai.runner, registry: registry,
                                               event_sink: sink, clock: Time,
                                               oauth_credential_provider: ctx[:creds])
      triage.call(batch_limit: 10)
      ai.process_runner.assert_consumed!
    end
    tasks = Task.where(source_plugin: "jira_oauth", source_resource_id: "issue:PROJ-1").order(:id).to_a
    expect(tasks.size).to eq(2)
    expect(tasks.map { |task| task.oauth_binding["generation"] }.sort).to eq([gen1, gen2].sort)
    expect(tasks.map(&:oauth_source_key).uniq.size).to eq(2)
    task2 = tasks.find { |task| task.oauth_binding["generation"] == gen2 }
    expect(task2.id == task1.id).to eq(false)
    # Each generation's own issue snapshot plus comment join to its own
    # Task: Task1 keeps its gen1 comment feedback, Task2 has its gen2
    # comment feedback, and neither gained the other's feedback.
    expect(task1.reload.task_feedbacks.count).to eq(1)
    expect(task2.reload.task_feedbacks.count).to eq(1)

    # A stale reply targeting the old Task rejects with no partial state:
    # no status/priority/plan change, no dispatch run, no extra action,
    # no feedback acknowledgement.
    feedback = TaskFeedback.create!(task: task1, body: "clarify old", author: "human")
    before = task1.reload.attributes.slice("status", "priority", "work_plan", "next_action_at", "last_error")
    actions_before = task1.outbound_actions.count
    runs_before = task1.task_runs.count
    stale = triage_newest.call({ "rulings" => [{ "task_id" => task1.id, "priority" => 99,
                                                 "status" => "ready", "dispatch" => true,
                                                 "work_plan" => "stale plan",
                                                 "reply" => { "body" => "stale reply" } }] })
    expect(stale.triaged).to eq(0)
    expect(stale.rejected).to eq(1)
    task1.reload
    expect(task1.attributes.slice("status", "priority", "work_plan")).to eq(before.slice("status", "priority", "work_plan"))
    expect(task1.outbound_actions.count).to eq(actions_before)
    expect(task1.task_runs.count).to eq(runs_before)
    expect(feedback.reload.processed_at.nil?).to eq(true)

    # The new Task replies fine under its own generation.
    fresh = triage_newest.call({ "rulings" => [{ "task_id" => task2.id, "reply" => { "body" => "ack gen2" } }] })
    expect(fresh.triaged).to eq(1)
    expect(task2.reload.outbound_actions.count).to eq(1)
    expect(task2.outbound_actions.first.oauth_binding["generation"]).to eq(gen2)
    expect(task1.reload.outbound_actions.count).to eq(actions_before)
    transport.assert_consumed!
  end
end

test("one jira poll ingests unrelated candidates while retaining held ones") do |db:|
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
                                       "input" => { "resource_id" => "issue:PROJ-1", "body" => "held reply" } }
                                   ] })
    expect(applied.ok).to eq(true)

    # One mixed response: PROJ-1 overlaps the pending reply (held),
    # PROJ-2 is unrelated human work (ingested) in the same batch.
    transport.expect_json(:POST, "#{OauthWorkflowSupport::JIRA_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [
                              OauthWorkflowSupport.jira_issue("PROJ-1", updated: "2026-09-26T12:40:00.000+0000"),
                              OauthWorkflowSupport.jira_issue("PROJ-2", updated: "2026-09-26T12:41:00.000+0000",
                                                              summary: "other", text: "other desc")
                            ]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("710", updated: "2026-09-26T12:42:00.000+0000", text: "held issue words")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    transport.expect_json(:GET, %r{/issue/PROJ-2/comment}, body:
      OauthWorkflowSupport.jira_page("comments", [
        OauthWorkflowSupport.jira_comment("711", updated: "2026-09-26T12:43:00.000+0000", text: "unrelated words")
      ]))
    transport.expect_json(:GET, %r{/issue/PROJ-2/changelog}, body: OauthWorkflowSupport.jira_page("values", []))
    mixed = poller.call(plugin: "jira_oauth", scope: "PROJ")
    expect(mixed.ok).to eq(false)
    expect(mixed.code).to eq(:held)
    # PROJ-2 ingests its issue snapshot plus comment; PROJ-1 (issue plus
    # comment) stays held without advancing the cursor.
    expect(mixed.ingested).to eq(2)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:711").nil?).to eq(false)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:issue:PROJ-2").nil?).to eq(false)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:comment:710").nil?).to eq(true)
    expect(ExternalEvent.find_by(plugin: "jira_oauth", event_id: "jira:issue:PROJ-1").nil?).to eq(true)
    expect(IntegrationCursor.find_by(plugin: "jira_oauth", scope: "PROJ").cursor.nil?).to eq(true)
    transport.assert_consumed!
  end
end

test("uncertain sends hold the same space after reconnect while old pending does not") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams_oauth:team/team-1/channel/chan-1,teams_oauth:team/team-1/channel/chan-2") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    result_service = Coordination::ResultService.new(registry: registry, event_sink: sink,
                                                     clock: Time, oauth_credential_provider: ctx[:creds])

    # An old pending (never started) for chan-1.
    pending_task = OauthWorkflowSupport.admin_task
    expect(result_service.apply(task_id: pending_task.id, task_version: pending_task.lock_version,
                                feedback_ids: [], policy: policy,
                                result: { "summary" => "s", "actions" => [
                                  { "plugin" => "teams_oauth", "operation" => "send_message",
                                    "input" => { "scope" => "channel:team-1/chan-1", "body" => "old pending" } }
                                ] }).ok).to eq(true)
    pending_action = OutboundAction.last
    expect(pending_action.request_started_at.nil?).to eq(true)

    # A started write for chan-1 that really times out -> uncertain.
    uncertain_task = OauthWorkflowSupport.admin_task
    expect(result_service.apply(task_id: uncertain_task.id, task_version: uncertain_task.lock_version,
                                feedback_ids: [], policy: policy,
                                result: { "summary" => "s", "actions" => [
                                  { "plugin" => "teams_oauth", "operation" => "send_message",
                                    "input" => { "scope" => "channel:team-1/chan-1", "body" => "uncertain write" } }
                                ] }).ok).to eq(true)
    uncertain_action = OutboundAction.last
    send_url = "#{OauthWorkflowSupport::GRAPH_BASE}/teams/team-1/channels/chan-1/messages"
    transport.expect_error(:POST, send_url,
                           Aiconshell::Plugins::TransportTimeout.new(http_method: "POST", url: send_url,
                                                                    timeout_kind: "read"))
    delivery = Interaction::OutboundService.new(registry: registry, event_sink: sink,
                                                oauth_credential_provider: ctx[:creds]).call(uncertain_action.id)
    expect(delivery.code).to eq(:delivery_uncertain)
    expect(uncertain_action.reload.status).to eq("uncertain")

    # Reconnect in the same tenant: generation moves, provider space stays.
    ctx[:auth].disconnect(provider: "microsoft")
    begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "s-uncertain-reconnect")
    OauthTestSupport.script_microsoft_callback(transport, principal: "user-oid-2")
    ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                        code: "auth-code-1", browser_session_id: "s-uncertain-reconnect")

    # Same destination still held by the uncertain side effect.
    OauthWorkflowSupport.script_teams_channel_message(transport, msg_id: "msg-same", body: "uncertain write")
    held = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(held.ok).to eq(false)
    expect(held.code).to eq(:held)
    expect(ExternalEvent.where(plugin: "teams_oauth").count).to eq(0)

    # Another destination in the same connection is unaffected.
    OauthWorkflowSupport.script_teams_channel_message(transport, team: "team-1", channel: "chan-2",
                                                      msg_id: "msg-other", body: "other channel words")
    other = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-2")
    expect(other.ok).to eq(true)
    expect(ExternalEvent.find_by(plugin: "teams_oauth",
                                 resource_id: "message:team-1/chan-2/msg-other").nil?).to eq(false)

    # The old pending alone never holds a reconnected poll: settle the
    # uncertain out of the way in this isolated check by marking it failed
    # (operator reconciliation), then the same destination ingests.
    uncertain_action.reload.update!(status: "failed", error_code: "reconciled", error: "operator review")
    pending_action.reload.update!(status: "failed", error_code: "reconciled", error: "operator review")
    OauthWorkflowSupport.script_teams_channel_message(transport, msg_id: "msg-after", body: "new human words")
    passed = poller.call(plugin: "teams_oauth", scope: "team/team-1/channel/chan-1")
    expect(passed.ok).to eq(true)
    expect(ExternalEvent.find_by(plugin: "teams_oauth",
                                 resource_id: "message:team-1/chan-1/msg-after").nil?).to eq(false)
    transport.assert_consumed!
  end
end

test("decision prompts map teams_oauth channels and chats to send input scopes") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "teams:team/t1/channel/c1,teams_oauth:team/team-1/channel/chan-1,teams_oauth:chat/chat-9,jira_oauth:PROJ") do
    transport = BoundaryFixtures::HttpTransport.new
    ctx = OauthWorkflowSupport.services_with(transport)
    OauthWorkflowSupport.connect_both(ctx)
    registry = OauthWorkflowSupport.build_registry(transport)
    sink = WorkflowFakes::FakeEventSink.new
    query = Interaction::QueryService.new(registry: registry, event_sink: sink,
                                          oauth_credential_provider: ctx[:creds])
    triage = Coordination::TriageService.new(ai_runner: nil, registry: registry,
                                             event_sink: sink, clock: Time,
                                             oauth_credential_provider: ctx[:creds])
    prompt = triage.send(:decision_prompt, [], [])
    capabilities = JSON.parse(prompt[/CAPABILITIES: (\{.*\})\nTASKS:/m, 1])
    targets = capabilities.fetch("allowed_targets")
    by_permission = targets.to_h { |entry| [[entry["plugin"], entry["permission_scope"]], entry["input_scope"]] }
    expect(by_permission[["teams", "team/t1/channel/c1"]]).to eq("channel:t1/c1")
    expect(by_permission[["teams_oauth", "team/team-1/channel/chan-1"]]).to eq("channel:team-1/chan-1")
    expect(by_permission[["teams_oauth", "chat/chat-9"]]).to eq("chat:chat-9")
    expect(by_permission[["jira_oauth", "PROJ"]]).to eq("PROJ")
    # The prompt never carries bindings or tokens; read scopes stay as-is.
    expect(prompt.include?("oauth_binding")).to eq(false)
    expect(prompt.include?("oauth_credential_provider")).to eq(false)
    expect(query.allowed_targets["teams_oauth"]).to include("team/team-1/channel/chan-1")
    transport.assert_consumed!
  end
end
