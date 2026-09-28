# frozen_string_literal: true

require "db_helper"
require "aiconshell/plugins"
require "aiconshell/ai"
require "openssl"
require_relative "workflow_test_helper"

class ReviewPollPlugin < Aiconshell::Plugins::Base
  plugin_id "review"
  operation "latest_events", input_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_INPUT,
    output_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_OUTPUT, scope: "review:poll-events"

  def handle_latest_events(_input, _context)
    { "events" => [WorkflowFakes::FakePluginRegistry.human_event], "cursor" => { "page" => 1 } }
  end
end

class ReviewGithubTransport
  attr_reader :calls
  def initialize = @calls = []
  def request(**request)
    @calls << request
    body = if request[:url].end_with?("/access_tokens")
      { token: "test-installation-token", expires_at: (Time.now + 3600).utc.iso8601 }
    else
      { id: 456, html_url: "https://github.com/owner/repo/issues/1#issuecomment-456" }
    end
    Aiconshell::Plugins::Http::Response.new(status: 201, body: JSON.generate(body))
  end
end

def review_sender(registry:, clock: Time, credential_source: nil)
  Interaction::OutboundService.new(registry: registry, clock: clock,
    ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: WorkflowFakes::FakeEventSink.new,
    credential_source: credential_source || WorkflowFakes::FakeCredentialSource.new)
end

def review_action(plugin: "github", input: { "resource_id" => "issue:owner/repo#1", "body" => "Update" }, **attrs)
  OutboundAction.create!({ plugin: plugin, operation: "reply", input: input,
    idempotency_key: SecureRandom.uuid }.merge(attrs))
end

def with_review_env(key, value)
  previous = ENV[key]
  value.nil? ? ENV.delete(key) : ENV[key] = value
  yield
ensure
  previous.nil? ? ENV.delete(key) : ENV[key] = previous
end

test("polling uses real registry operation permissions and schemas") do |db:|
  with_workflow_env(scopes: "review:inbox") do
    registry = Aiconshell::Plugins::Registry.new(env: {}).register(ReviewPollPlugin.new)
    result = Interaction::PollService.new(registry: registry).call(plugin: "review", scope: "inbox")
    expect(result.ok).to eq(true)
    expect(ExternalEvent.count).to eq(1)
    expect(IntegrationCursor.first.cursor).to eq({ "page" => 1 })
  end
end

test("GitHub reply crosses the real registry with repository authorization") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    transport = ReviewGithubTransport.new
    env = { "GITHUB_APP_ID" => "123", "GITHUB_INSTALLATION_ID" => "456",
      "GITHUB_PRIVATE_KEY" => OpenSSL::PKey::RSA.new(2048).to_pem }
    registry = Aiconshell::Plugins::Registry.new(env: {}, transport: transport)
      .register(Aiconshell::Plugins::Github.new)
    source = WorkflowFakes::FakeCredentialSource.new("github" => env)
    action = review_action
    expect(review_sender(registry: registry, credential_source: source).call(action.id).ok).to eq(true)
    expect(action.reload.external_id).to eq("456")
    expect(transport.calls.last[:url]).to eq("https://api.github.com/repos/owner/repo/issues/1/comments")
    expect(JSON.parse(transport.calls.last[:body])).to eq({ "body" => "Update" })
  end
end

test("forged reply scope cannot authorize a different repository") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    registry = WorkflowFakes::FakePluginRegistry.new
    action = review_action(input: { "resource_id" => "issue:evil/repo#1", "scope" => "owner/repo", "body" => "Update" })
    expect(review_sender(registry: registry).call(action.id).code).to eq(:scope_not_allowed)
    expect(registry.invocations).to eq([])
  end
end

test("stale poll writes neither events nor a replacement cursor") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    registry = Object.new
    registry.define_singleton_method(:invoke) do |**_args|
      IntegrationCursor.first.update!(lease_token: "new-holder", lease_expires_at: 10.minutes.from_now)
      { "events" => [WorkflowFakes::FakePluginRegistry.human_event], "cursor" => { "page" => 99 } }
    end
    result = Interaction::PollService.new(registry: registry).call(plugin: "github", scope: "owner/repo")
    expect(result.code).to eq(:stale_poll)
    expect(ExternalEvent.count).to eq(0)
    expect(IntegrationCursor.first.cursor).to eq(nil)
    expect(IntegrationCursor.first.lease_token).to eq("new-holder")
  end
end

test("PostgreSQL insert failure retains cursor and does not poison the caller transaction") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    db.execute("ALTER TABLE external_events ADD CONSTRAINT review_reject_actor CHECK (actor_id <> 'reject')")
    event = WorkflowFakes::FakePluginRegistry.human_event(actor_id: "reject")
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: { "owner/repo" => [event] })
    result = Interaction::PollService.new(registry: registry).call(plugin: "github", scope: "owner/repo")
    expect(result.ok).to eq(false)
    expect(ExternalEvent.count).to eq(0)
    expect(IntegrationCursor.first.cursor).to eq(nil)
    expect(IntegrationCursor.first.lease_token).to eq(nil)
    expect(db.select_value("SELECT 1")).to eq(1)
  end
end

test("system context is preserved while configured self-actor echoes are ignored") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    with_review_env("AICONSHELL_SELF_ACTOR_IDS", "github:service-account") do
      human = WorkflowFakes::FakePluginRegistry.human_event(actor_id: "service-account")
      system = WorkflowFakes::FakePluginRegistry.human_event(event_id: "status", actor_id: "system")
        .merge("actor_type" => "system")
      registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: { "owner/repo" => [human, system] })
      Interaction::PollService.new(registry: registry).call(plugin: "github", scope: "owner/repo")
      expect(ExternalEvent.find_by(event_id: human["event_id"]).processed?).to eq(true)
      expect(ExternalEvent.find_by(event_id: "status").processed?).to eq(false)
    end
  end
end

test("crashed remote sends remain uncertain and are never automatically reposted") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    registry = WorkflowFakes::FakePluginRegistry.new
    action = review_action(status: "sending", lease_token: "old", lease_expires_at: 1.minute.ago,
      request_started_at: 2.minutes.ago)
    sender = review_sender(registry: registry)
    sender.recover_expired!
    expect(action.reload.status).to eq("uncertain")
    expect(sender.call(action.id).code).to eq(:duplicate_delivery)
    expect(registry.invocations).to eq([])
  end
end

test("expired local drafts recover with backoff and stale responses cannot settle") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    registry = WorkflowFakes::FakePluginRegistry.new
    action = review_action(status: "sending", lease_token: "old", lease_expires_at: 1.minute.ago)
    sender = review_sender(registry: registry)
    sender.recover_expired!
    expect(action.reload.status).to eq("pending")
    expect(sender.call(action.id).code).to eq(:not_due)
    action.update!(next_attempt_at: nil)
    registry.define_singleton_method(:invoke) do |**_args|
      action.update!(status: "uncertain", lease_token: nil, lease_expires_at: nil)
      { "external_id" => "late", "url" => nil }
    end
    expect(sender.call(action.id).code).to eq(:stale_delivery)
    expect(action.reload.status).to eq("uncertain")
    expect(action.external_id).to eq(nil)
  end
end

test("rate limit rejection uses Retry-After and stops at the attempt budget") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    with_review_env("AICONSHELL_MAX_ACTION_ATTEMPTS", "2") do
      clock = Struct.new(:current).new(Time.current)
      error = Aiconshell::Plugins::RateLimited.new(status: 429, http_method: "POST", url: "https://api.github.com/", retry_after: 90)
      registry = WorkflowFakes::FakePluginRegistry.new(errors: { "github#reply" => error })
      action = review_action
      sender = review_sender(registry: registry, clock: clock)
      expect(sender.call(action.id).code).to eq(:rate_limited)
      expect(action.reload.next_attempt_at.to_i).to eq((clock.current + 90).to_i)
      expect(sender.call(action.id).code).to eq(:not_due)
      clock.current += 91
      expect(sender.call(action.id).code).to eq(:attempts_exhausted)
      expect(action.reload.status).to eq("failed")
    end
  end
end

test("arbitrary transport output never enters persisted delivery errors") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    registry = WorkflowFakes::FakePluginRegistry.new(errors: {
      "github#reply" => WorkflowFakes::FakeTransportError.new("private-unprefixed-sentinel")
    })
    action = review_action
    expect(review_sender(registry: registry).call(action.id).code).to eq(:delivery_uncertain)
    expect(action.reload.error.include?("private-unprefixed-sentinel")).to eq(false)
  end
end
