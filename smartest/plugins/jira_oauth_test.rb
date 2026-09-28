# frozen_string_literal: true

require_relative "plugins_test_helper"
require_relative "../support/boundary_fixtures"
require_relative "../../lib/aiconshell/oauth"
require_relative "../../lib/aiconshell/plugins/jira_oauth"

JoPlugins = Aiconshell::Plugins
JOAUTH_CLOUD = "11111111-2222-3333-4444-555555555555"
JOAUTH_OTHER_CLOUD = "22222222-3333-4444-5555-666666666666"
JOAUTH_BASE = "https://api.atlassian.com/ex/jira/#{JOAUTH_CLOUD}"
JOAUTH_ENV = {
  "OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client",
  "OAUTH_ATLASSIAN_CLIENT_SECRET" => "atl-secret",
  "OAUTH_ATLASSIAN_CLOUD_ID" => JOAUTH_CLOUD,
  "OAUTH_ATLASSIAN_REDIRECT_URI" => "https://app.example.test/oauth/atlassian/callback"
}.freeze

class JoFakeProvider
  attr_reader :token_calls, :binding_calls, :last_binding

  def initialize(token: "jo-token-1", error: nil)
    @token = token
    @error = error
    @token_calls = 0
    @binding_calls = 0
    @last_binding = nil
  end

  def access_token(binding)
    @token_calls += 1
    @last_binding = binding
    raise @error if @error

    @token
  end

  def binding_for(_provider)
    @binding_calls += 1
    raise "binding_for must not be called by jira_oauth"
  end
end

class JoClock
  def initialize(now)
    @now = now
  end

  def now
    @now
  end
end

def jo_binding(overrides = {})
  {
    "connection_id" => 7,
    "generation" => 3,
    "provider" => "atlassian",
    "principal" => "acc-123",
    "tenant" => nil,
    "cloud" => JOAUTH_CLOUD
  }.merge(overrides)
end

def jo_registry(transport, env: JOAUTH_ENV, provider: nil, clock: JoClock.new(Time.utc(2026, 9, 26, 12, 0, 0)))
  registry = JoPlugins::Registry.new(env: env, transport: transport, clock: clock)
  registry.register(JoPlugins::JiraOauth.new(credential_provider: provider))
  registry
end

def jo_context(binding_hash, provider, scopes: nil)
  ctx = { "oauth_binding" => binding_hash, "oauth_credential_provider" => provider }
  ctx["scopes"] = scopes unless scopes.nil?
  ctx
end

def jo_adf(text)
  { "type" => "doc", "version" => 1,
    "content" => [{ "type" => "paragraph",
                    "content" => [{ "type" => "text", "text" => text }] }] }
end

def jo_issue(key, updated:, summary: "summary", description: nil, status: "To Do")
  { "id" => "100#{key.split("-").last}", "key" => key,
    "fields" => { "summary" => summary,
                  "description" => description || jo_adf("desc of #{key}"),
                  "status" => { "name" => status },
                  "updated" => updated, "created" => "2026-09-20T10:00:00.000+0000" } }
end

def jo_page(collection, values, start_at: 0, max_results: 50, total: nil)
  { collection => values, "startAt" => start_at, "maxResults" => max_results,
    "total" => total || values.length }
end

def jo_comment(id, updated:, text: "comment", author: "u1", account_type: "atlassian")
  { "id" => id, "body" => jo_adf(text),
    "created" => "2026-09-20T12:00:00Z", "updated" => updated,
    "author" => { "accountId" => author, "accountType" => account_type } }
end

def jo_empty_children(transport, key: "PROJ-1")
  transport.expect_json(:GET, %r{/issue/#{key}/comment}, body: jo_page("comments", []))
  transport.expect_json(:GET, %r{/issue/#{key}/changelog}, body: jo_page("values", []))
end

test("jira_oauth catalog uses independent scopes and env without registering default") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)
  entry = registry.catalog.find { |item| item["id"] == "jira_oauth" }

  expect(entry["required_env"].sort).to eq(
    %w[OAUTH_ATLASSIAN_CLIENT_ID OAUTH_ATLASSIAN_CLIENT_SECRET
       OAUTH_ATLASSIAN_CLIENT_SECRET_FILE OAUTH_ATLASSIAN_CLOUD_ID
       OAUTH_ATLASSIAN_REDIRECT_URI].sort
  )
  ops = entry["operations"].to_h { |op| [op["name"], op] }
  expect(ops.keys.sort).to eq(%w[create_issue latest_events reply])
  expect(ops["latest_events"]["scope"]).to eq("jira_oauth:read")
  expect(ops["latest_events"]["read_only"]).to eq(true)
  expect(ops["reply"]["scope"]).to eq("jira_oauth:write")
  expect(ops["create_issue"]["scope"]).to eq("jira_oauth:write")
  expect(entry["configured"]).to eq(true)

  bare = JoPlugins::Registry.new(env: {}, transport: transport, clock: Time)
  bare.register(JoPlugins::JiraOauth.new)
  expect(bare.catalog.find { |item| item["id"] == "jira_oauth" }["configured"]).to eq(false)

  # Input schemas never carry the trusted binding/provider.
  expect(ops["latest_events"]["input_schema"]["additionalProperties"]).to eq(false)
  expect(ops["latest_events"]["input_schema"]["properties"].keys.sort).to eq(%w[cursor scope])

  # Business wiring (#26) registers the delegated adapters in the default
  # registry with pure-Ruby instances (no Rails provider held).
  expect(JoPlugins::Registry.default.catalog.map { |item| item["id"] }.sort).to eq(
    %w[discord github jira jira_oauth teams teams_oauth]
  )
  transport.assert_consumed!
end

test("jira_oauth poll uses Bearer on the verified cloud with no JQL time predicate") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new(token: "bearer-abc")
  registry = jo_registry(transport, provider: provider)
  binding = jo_binding

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000")]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body: {
                          "startAt" => 0, "maxResults" => 50, "total" => 1,
                          "comments" => [jo_comment("200", updated: "2026-09-26T12:02:00.000+0000", text: "first")]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: jo_page("values", []))

  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ" },
                        context: jo_context(binding, provider, scopes: ["jira_oauth:read"]))

  search = transport.requests_to("#{JOAUTH_BASE}/rest/api/3/search/jql", method: :POST)
  expect(search.size).to eq(1)
  jql = JSON.parse(search.first[:body])["jql"]
  expect(jql).to eq("project = PROJ ORDER BY updated ASC")
  expect(search.first[:headers]["Authorization"]).to eq("Bearer bearer-abc")
  expect(search.first[:url]).to start_with(JOAUTH_BASE)
  expect(transport.requests_to(%r{api\.atlassian\.com}).size).to eq(3)
  expect(provider.token_calls).to eq(1)
  expect(provider.binding_calls).to eq(0)

  ids = out["events"].map { |event| event["event_id"] }
  expect(ids).to eq(["jira:issue:PROJ-1", "jira:comment:200"])
  expect(out["events"][1]["payload"]["text"]).to eq("first")
  expect(out["events"][1]["actor_type"]).to eq("human")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:02:00Z" })
  transport.assert_consumed!
end

test("jira_oauth filters by instant in Ruby so non-UTC users need no UTC setting") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [
                            jo_issue("PROJ-1", updated: "2026-09-26T11:00:00Z"),
                            jo_issue("PROJ-2", updated: "2026-09-26T21:00:00+09:00")
                          ]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body: jo_page("comments", []))
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: jo_page("values", []))
  transport.expect_json(:GET, %r{/issue/PROJ-2/comment}, body: jo_page("comments", []))
  transport.expect_json(:GET, %r{/issue/PROJ-2/changelog}, body: jo_page("values", []))

  # 21:00+09:00 is 12:00Z; cutoff is 11:55Z, so PROJ-1 (11:00Z) drops.
  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ", "cursor" => { "since" => "2026-09-26T21:00:00+09:00" } },
                        context: jo_context(jo_binding, provider))

  jql = JSON.parse(transport.requests.first[:body])["jql"]
  expect(jql).to eq("project = PROJ ORDER BY updated ASC")
  expect(out["events"].map { |event| event["resource_id"] }).to eq(["issue:PROJ-2"])
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:00:00Z" })
  transport.assert_consumed!
end

test("jira_oauth rejects wildcard scopes explicitly before any I/O") do
  [nil, { "since" => "2026-09-26T12:00:00Z" }].each do |cursor|
    transport = BoundaryFixtures::HttpTransport.new
    provider = JoFakeProvider.new
    registry = jo_registry(transport, provider: provider)
    input = { "scope" => "*" }
    input["cursor"] = cursor unless cursor.nil?

    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                      input: input, context: jo_context(jo_binding, provider))
    rescue JoPlugins::InputInvalid => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(raised.message).to match(/not supported/)
    expect(transport.requests).to eq([])
    expect(provider.token_calls).to eq(0)
    transport.assert_consumed!

    raised = nil
    begin
      registry.validate_input(plugin: "jira_oauth", operation: "latest_events",
                              input: input, context: {})
    rescue JoPlugins::InputInvalid => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
  end
end

test("jira_oauth reconciles old-issue comment edits with stable ids and human actors") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [jo_issue("PROJ-1", updated: "2026-09-01T12:00:00Z")]
                        })
  comments = [jo_comment("edited", updated: "2026-09-26T05:01:00-07:00", text: "edited body"),
              jo_comment("equal", updated: "2026-09-26T12:00:00Z"),
              jo_comment("delayed", updated: "2026-09-26T11:55:00Z"),
              jo_comment("old", updated: "2026-09-26T20:00:00+09:00")]
  comments.first["updateAuthor"] = { "accountId" => "editor" }
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body: jo_page("comments", comments))
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: jo_page("values", []))

  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ", "cursor" => { "since" => "2026-09-26T12:00:00Z" } },
                        context: jo_context(jo_binding, provider))

  expect(out["events"].map { |event| event["event_id"] }).to eq(
    ["jira:comment:delayed", "jira:comment:equal", "jira:comment:edited"]
  )
  expect(out["events"].last["actor_id"]).to eq("editor")
  expect(out["events"].last["actor_type"]).to eq("human")
  expect(out["events"].last["payload"]["text"]).to eq("edited body")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:01:00Z" })
  transport.assert_consumed!
end

test("jira_oauth keeps app-provided actor types and never forges bot") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:01:00Z")]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body: {
                          "startAt" => 0, "maxResults" => 50, "total" => 2,
                          "comments" => [
                            jo_comment("1", updated: "2026-09-26T12:02:00Z", author: "human-1"),
                            jo_comment("2", updated: "2026-09-26T12:03:00Z", author: "app-1",
                                       account_type: "app")
                          ]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: jo_page("values", []))

  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))
  by_id = out["events"].to_h { |event| [event["event_id"], event] }
  expect(by_id["jira:comment:1"]["actor_type"]).to eq("human")
  expect(by_id["jira:comment:2"]["actor_type"]).to eq("bot")
  transport.assert_consumed!
end

test("jira_oauth pages search, comments, and changelog to completion") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [], "nextPageToken" => "tok-2"
                        })
  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment\?.*startAt=0}, body:
    jo_page("comments", [jo_comment("c0", updated: "2026-09-26T12:01:00Z")],
            start_at: 0, max_results: 1, total: 2))
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
    jo_page("comments", [jo_comment("c1", updated: "2026-09-26T12:02:00Z")],
            start_at: 1, max_results: 1, total: 2))
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog\?.*startAt=0}, body:
    jo_page("values", [{ "id" => "h0", "created" => "2026-09-26T12:03:00Z", "items" => [] }],
            start_at: 0, max_results: 1, total: 2))
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body:
    jo_page("values", [{ "id" => "h1", "created" => "2026-09-26T12:04:00Z", "items" => [] }],
            start_at: 1, max_results: 1, total: 2))

  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))

  expect(out["events"].count { |event| event["event_type"] == "jira.comment" }).to eq(2)
  expect(out["events"].count { |event| event["event_type"] == "jira.change" }).to eq(2)
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:04:00Z" })
  expect(provider.token_calls).to eq(1)
  transport.assert_consumed!
end

test("jira_oauth raises IncompletePoll at the search cap and keeps the input cursor") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)

  JoPlugins::JiraOauth::MAX_PAGES.times do |index|
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [], "nextPageToken" => "page-#{index + 1}"
                          })
  end
  cursor = { "since" => "2026-09-26T12:00:00Z" }

  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                    input: { "scope" => "PROJ", "cursor" => cursor },
                    context: jo_context(jo_binding, provider))
  rescue JoPlugins::IncompletePoll => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(raised.message).to match(/page limit/)
  expect(cursor).to eq({ "since" => "2026-09-26T12:00:00Z" })
  transport.assert_consumed!
end

test("jira_oauth refuses cross-cloud, path-escape, and cross-host nextPage without credentials") do
  bad_targets = [
    "https://api.atlassian.com/ex/jira/#{JOAUTH_OTHER_CLOUD}/rest/api/3/issue/PROJ-1/comment?startAt=1",
    "https://api.atlassian.com/ex/jira/#{JOAUTH_CLOUD}/../other/rest/api/3/issue/PROJ-1/comment",
    "https://evil.test/api/comments?token=2"
  ]
  bad_targets.each do |target|
    transport = BoundaryFixtures::HttpTransport.new
    provider = JoFakeProvider.new
    registry = jo_registry(transport, provider: provider)
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body:
      jo_page("comments", [], start_at: 0, max_results: 50, total: 2).merge("nextPage" => target))

    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                      input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))
    rescue JoPlugins::HostRejected => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(transport.requests_to(%r{evil\.test}).size).to eq(0)
    expect(transport.requests_to(/#{Regexp.escape(JOAUTH_OTHER_CLOUD)}/).size).to eq(0)
    transport.assert_consumed!
  end
end

test("jira_oauth reply and create_issue send ADF with Bearer and stable external ids") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new(token: "write-token")
  registry = jo_registry(transport, provider: provider)
  ctx = jo_context(jo_binding, provider, scopes: ["jira_oauth:write"])

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment",
                        status: 201, body: { "id" => "500" })
  out = registry.invoke(plugin: "jira_oauth", operation: "reply",
                        input: { "resource_id" => "issue:PROJ-1", "body" => "on it" },
                        context: ctx)
  expect(out).to eq({ "external_id" => "500", "url" => nil })
  posted = transport.requests_to("#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment", method: :POST)
  expect(posted.size).to eq(1)
  expect(posted.first[:headers]["Authorization"]).to eq("Bearer write-token")
  comment_body = JSON.parse(posted.first[:body])
  expect(comment_body["body"]["type"]).to eq("doc")
  expect(comment_body["body"]["content"][0]["content"][0]["text"]).to eq("on it")

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/issue",
                        status: 201, body: { "id" => "101", "key" => "PROJ-42" })
  out = registry.invoke(plugin: "jira_oauth", operation: "create_issue",
                        input: { "scope" => "PROJ", "title" => "bug", "body" => "steps" },
                        context: ctx)
  expect(out).to eq({ "external_id" => "PROJ-42", "url" => nil })
  issue_posted = transport.requests_to("#{JOAUTH_BASE}/rest/api/3/issue", method: :POST)
  expect(issue_posted.size).to eq(1)
  issue_body = JSON.parse(issue_posted.first[:body])
  expect(issue_body["fields"]["project"]).to eq({ "key" => "PROJ" })
  expect(issue_body["fields"]["issuetype"]).to eq({ "name" => "Task" })
  expect(provider.token_calls).to eq(2)
  transport.assert_consumed!
end

test("jira_oauth never replays a write on 401 and resolves one token per invoke") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new(token: "single-token")
  registry = jo_registry(transport, provider: provider)

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment",
                        status: 401, body: { "errorMessages" => ["unauthorized"] })
  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "reply",
                    input: { "resource_id" => "issue:PROJ-1", "body" => "hi" },
                    context: jo_context(jo_binding, provider))
  rescue JoPlugins::HttpError => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(raised.status).to eq(401)
  expect(provider.token_calls).to eq(1)
  expect(transport.requests_to("#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment", method: :POST).size).to eq(1)
  transport.assert_consumed!
end

test("jira_oauth keeps parallel bindings separate") do
  first_transport = BoundaryFixtures::HttpTransport.new
  second_transport = BoundaryFixtures::HttpTransport.new
  first_provider = JoFakeProvider.new(token: "token-user-1")
  second_provider = JoFakeProvider.new(token: "token-user-2")
  first_registry = jo_registry(first_transport, provider: first_provider)
  second_registry = jo_registry(second_transport, provider: second_provider)
  first_binding = jo_binding("connection_id" => 11, "generation" => 1, "principal" => "user-1")
  second_binding = jo_binding("connection_id" => 22, "generation" => 5, "principal" => "user-2")

  [first_transport, second_transport].each do |transport|
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-9/comment",
                          status: 201, body: { "id" => "900" })
  end

  first_registry.invoke(plugin: "jira_oauth", operation: "reply",
                        input: { "resource_id" => "issue:PROJ-9", "body" => "a" },
                        context: jo_context(first_binding, first_provider))
  second_registry.invoke(plugin: "jira_oauth", operation: "reply",
                         input: { "resource_id" => "issue:PROJ-9", "body" => "b" },
                         context: jo_context(second_binding, second_provider))

  expect(first_transport.requests.first[:headers]["Authorization"]).to eq("Bearer token-user-1")
  expect(second_transport.requests.first[:headers]["Authorization"]).to eq("Bearer token-user-2")
  first_principal = first_provider.last_binding.is_a?(Hash) ? first_provider.last_binding["principal"] : first_provider.last_binding.principal
  second_principal = second_provider.last_binding.is_a?(Hash) ? second_provider.last_binding["principal"] : second_provider.last_binding.principal
  expect(first_principal).to eq("user-1")
  expect(second_principal).to eq("user-2")
  first_transport.assert_consumed!
  second_transport.assert_consumed!
end

test("jira_oauth requires the trusted binding and provider before any HTTP") do
  provider = JoFakeProvider.new

  transport = BoundaryFixtures::HttpTransport.new
  registry = jo_registry(transport, provider: provider,
                         env: JOAUTH_ENV.merge("JIRA_EMAIL" => "bot@example.com",
                                               "JIRA_API_TOKEN" => "service-token",
                                               "JIRA_SITE_URL" => "https://svc.atlassian.net"))
  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                    input: { "scope" => "PROJ" }, context: {})
  rescue JoPlugins::CredentialsMissing => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(transport.requests).to eq([])
  expect(provider.token_calls).to eq(0)
  transport.assert_consumed!

  transport = BoundaryFixtures::HttpTransport.new
  registry = jo_registry(transport, provider: nil)
  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "reply",
                    input: { "resource_id" => "issue:PROJ-1", "body" => "hi" },
                    context: { "oauth_binding" => jo_binding })
  rescue JoPlugins::CredentialsMissing => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(raised.message).to match(/oauth_credential_provider/)
  expect(transport.requests).to eq([])
  transport.assert_consumed!

  invalid_bindings = [
    jo_binding("provider" => "microsoft", "cloud" => nil, "tenant" => "t-1"),
    jo_binding("cloud" => "not-a-cloud-id"),
    jo_binding("principal" => ""),
    jo_binding("cloud" => JOAUTH_OTHER_CLOUD)
  ]
  # The last entry has a well-formed but unexpected cloud: the adapter still
  # refuses to use ambient env and stays inside the binding's own cloud.
  # Only the malformed ones raise here; the well-formed other-cloud binding
  # is exercised by the nextPage test with its own base.
  invalid_bindings.first(3).each do |bad|
    transport = BoundaryFixtures::HttpTransport.new
    registry = jo_registry(transport, provider: provider)
    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                      input: { "scope" => "PROJ" },
                      context: jo_context(bad, provider))
    rescue JoPlugins::CredentialsMissing => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(transport.requests).to eq([])
    transport.assert_consumed!
  end
end

test("jira_oauth accepts constructor injection and Binding objects") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new(token: "ctor-token")
  registry = jo_registry(transport, provider: provider)
  binding_object = Aiconshell::Oauth::Binding.from_h(jo_binding)

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: { "issues" => [] })
  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ" },
                        context: { "oauth_binding" => binding_object,
                                   "oauth_credential_provider" => provider })
  expect(out["events"]).to eq([])
  expect(provider.token_calls).to eq(1)
  expect(provider.binding_calls).to eq(0)
  transport.assert_consumed!

  injected = JoFakeProvider.new(token: "injected-only")
  bare = JoPlugins::Registry.new(env: JOAUTH_ENV, transport: transport,
                                 clock: JoClock.new(Time.utc(2026, 9, 26, 12, 0, 0)))
  bare.register(JoPlugins::JiraOauth.new(credential_provider: injected))
  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: { "issues" => [] })
  bare.invoke(plugin: "jira_oauth", operation: "latest_events",
              input: { "scope" => "PROJ" },
              context: { "oauth_binding" => jo_binding })
  expect(injected.token_calls).to eq(1)
  transport.assert_consumed!
end

test("jira_oauth enforces its own read/write scopes independently from jira") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)
  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: { "issues" => [] })

  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ" },
                        context: jo_context(jo_binding, provider, scopes: ["jira_oauth:read"]))
  expect(out["events"]).to eq([])

  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                    input: { "scope" => "PROJ" },
                    context: jo_context(jo_binding, provider, scopes: ["jira:read"]))
  rescue JoPlugins::PermissionDenied => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(raised.required_scope).to eq("jira_oauth:read")

  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "reply",
                    input: { "resource_id" => "issue:PROJ-1", "body" => "hi" },
                    context: jo_context(jo_binding, provider, scopes: ["jira_oauth:read"]))
  rescue JoPlugins::PermissionDenied => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(raised.required_scope).to eq("jira_oauth:write")
  expect(transport.requests.size).to eq(1)
  transport.assert_consumed!
end

test("jira_oauth surfaces 429 and connection failures without secrets or extra I/O") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)
  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql",
                        status: 429, body: {}, headers: { "Retry-After" => "2" })
  raised = nil
  begin
    registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                    input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))
  rescue JoPlugins::RateLimited => error
    raised = error
  end
  expect(raised.nil?).to eq(false)
  expect(raised.message).not_to include("jo-token-1")
  transport.assert_consumed!

  failure_map = {
    "not_connected" => Aiconshell::Oauth::ProviderError.new("not_connected"),
    "binding_mismatch" => Aiconshell::Oauth::BindingMismatch.new,
    "refresh_busy" => Aiconshell::Oauth::RefreshBusy.new,
    "invalid_grant" => Aiconshell::Oauth::ProviderError.new("invalid_grant")
  }
  failure_map.each_value do |failure|
    failing_transport = BoundaryFixtures::HttpTransport.new
    failing_provider = JoFakeProvider.new(error: failure)
    failing_registry = jo_registry(failing_transport, provider: failing_provider)
    raised = nil
    begin
      failing_registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                              input: { "scope" => "PROJ" },
                              context: jo_context(jo_binding, failing_provider))
    rescue StandardError => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(raised.message).not_to include("jo-token-1")
    expect(failing_transport.requests).to eq([])
    failing_transport.assert_consumed!
  end

  expect(JoPlugins::JiraOauth.new.inspect).not_to include("jo-token-1")
  expect(Aiconshell::Oauth::Binding.from_h(jo_binding).inspect).not_to include("acc-123")
  expect(JSON.generate(jo_registry(transport, provider: provider).catalog)).not_to include("jo-token-1")
end

test("jira_oauth validates input and cursors before resolving credentials") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)

  invalid_inputs = [
    ["latest_events", { "scope" => "lowercase" }],
    ["latest_events", { "scope" => "PROJ", "cursor" => { "since" => "not-a-time" } }],
    ["latest_events", { "scope" => "PROJ", "cursor" => { "since" => "2026-09-26T24:00:00Z" } }],
    ["reply", { "resource_id" => "PROJ-1", "body" => "hi" }],
    ["create_issue", { "scope" => "*", "title" => "t", "body" => "b" }]
  ]
  invalid_inputs.each do |operation, input|
    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: operation,
                      input: input, context: jo_context(jo_binding, provider))
    rescue JoPlugins::InputInvalid => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
  end
  expect(transport.requests).to eq([])
  expect(provider.token_calls).to eq(0)
  transport.assert_consumed!
end

test("jira_oauth pins nextPage to the same issue and collection") do
  bad_targets = [
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-2/comment?startAt=1&maxResults=1",
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/changelog?startAt=1&maxResults=50",
    "#{JOAUTH_BASE}/rest/api/3/issue/OTHER-9/comment?startAt=1&maxResults=50"
  ]
  bad_targets.each do |target|
    transport = BoundaryFixtures::HttpTransport.new
    provider = JoFakeProvider.new
    registry = jo_registry(transport, provider: provider)
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body: {
                            "comments" => [jo_comment("c0", updated: "2026-09-26T12:01:00Z")],
                            "startAt" => 0, "maxResults" => 1, "total" => 2,
                            "nextPage" => target
                          })

    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                      input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))
    rescue JoPlugins::HostRejected => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(transport.requests_to(target, method: :GET).size).to eq(0)
    expect(transport.requests.size).to eq(2)
    transport.assert_consumed!
  end
end

test("jira_oauth follows a same-collection nextPage with paging query") do
  transport = BoundaryFixtures::HttpTransport.new
  provider = JoFakeProvider.new
  registry = jo_registry(transport, provider: provider)
  valid_next = "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment?startAt=1&maxResults=1&orderBy=created"

  transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                          "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")]
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment\?.*startAt=0}, body: {
                          "comments" => [jo_comment("c0", updated: "2026-09-26T12:01:00Z")],
                          "startAt" => 0, "maxResults" => 1, "total" => 2,
                          "nextPage" => valid_next
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/comment\?.*startAt=1}, body: {
                          "comments" => [jo_comment("c1", updated: "2026-09-26T12:02:00Z")],
                          "startAt" => 1, "maxResults" => 1, "total" => 2
                        })
  transport.expect_json(:GET, %r{/issue/PROJ-1/changelog}, body: jo_page("values", []))

  out = registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                        input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))
  expect(out["events"].map { |event| event["event_id"] }).to include("jira:comment:c1")
  expect(transport.requests_to(valid_next, method: :GET).size).to eq(1)
  transport.assert_consumed!
end

test("jira_oauth rejects encoded and noncanonical nextPage paths before HTTP") do
  bad_targets = [
    "#{JOAUTH_BASE}/rest/api/3/issue/%2e%2e/comment?startAt=1&maxResults=50",
    "#{JOAUTH_BASE}/rest/api/3/issue/%2E%2E/comment?startAt=1&maxResults=50",
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1%2fcomment?startAt=1",
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1%5ccomment?startAt=1",
    "#{JOAUTH_BASE}/rest/api/3/issue/%252e/comment?startAt=1",
    "#{JOAUTH_BASE}/rest/api/3/issue//comment?startAt=1&maxResults=50",
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment/?startAt=1&maxResults=50",
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment?startAt=1&maxResults=50#frag",
    "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment?startAt=1&jql=evil",
    "https://user:secret@api.atlassian.com/ex/jira/#{JOAUTH_CLOUD}/rest/api/3/issue/PROJ-1/comment?startAt=1"
  ]
  bad_targets.each do |target|
    transport = BoundaryFixtures::HttpTransport.new
    provider = JoFakeProvider.new
    registry = jo_registry(transport, provider: provider)
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/search/jql", body: {
                            "issues" => [jo_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")]
                          })
    transport.expect_json(:GET, %r{/issue/PROJ-1/comment}, body: {
                            "comments" => [jo_comment("c0", updated: "2026-09-26T12:01:00Z")],
                            "startAt" => 0, "maxResults" => 1, "total" => 2,
                            "nextPage" => target
                          })

    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "latest_events",
                      input: { "scope" => "PROJ" }, context: jo_context(jo_binding, provider))
    rescue JoPlugins::HostRejected => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(transport.requests.size).to eq(2)
    transport.assert_consumed!
  end
end

test("jira_oauth validates write receipts strictly without to_s coercion") do
  bad_comment_ids = [123, { "x" => 1 }, "", "abc", "12a", nil]
  bad_comment_ids.each do |bad_id|
    transport = BoundaryFixtures::HttpTransport.new
    provider = JoFakeProvider.new(token: "write-token")
    registry = jo_registry(transport, provider: provider)
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/issue/PROJ-1/comment",
                          status: 201, body: { "id" => bad_id })
    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "reply",
                      input: { "resource_id" => "issue:PROJ-1", "body" => "hi" },
                      context: jo_context(jo_binding, provider, scopes: ["jira_oauth:write"]))
    rescue JoPlugins::OutputInvalid => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(raised.message).to match(/comment id/)
    expect(transport.requests.size).to eq(1)
    transport.assert_consumed!
  end

  bad_issue_keys = [42, { "key" => "PROJ-1" }, "", "lower-1", "PROJ-", "PROJ-abc",
                    "OTHER-1", "PROJX-1", nil]
  bad_issue_keys.each do |bad_key|
    transport = BoundaryFixtures::HttpTransport.new
    provider = JoFakeProvider.new(token: "write-token")
    registry = jo_registry(transport, provider: provider)
    transport.expect_json(:POST, "#{JOAUTH_BASE}/rest/api/3/issue",
                          status: 201, body: { "id" => "101", "key" => bad_key })
    raised = nil
    begin
      registry.invoke(plugin: "jira_oauth", operation: "create_issue",
                      input: { "scope" => "PROJ", "title" => "t", "body" => "b" },
                      context: jo_context(jo_binding, provider, scopes: ["jira_oauth:write"]))
    rescue JoPlugins::OutputInvalid => error
      raised = error
    end
    expect(raised.nil?).to eq(false)
    expect(raised.message).to match(/issue key/)
    expect(transport.requests.size).to eq(1)
    transport.assert_consumed!
  end
end
