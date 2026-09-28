# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

class PollScheduleForbiddenTransport
  attr_reader :calls

  def initialize
    @calls = []
  end

  def request(**arguments)
    @calls << arguments
    raise "Scheduler must not invoke a remote API"
  end
end

def poll_schedule_registry
  transport = PollScheduleForbiddenTransport.new
  registry = Aiconshell::Plugins::Registry.new(env: {}, transport: transport)
  registry.register(Aiconshell::Plugins::Github.new)
  registry.register(Aiconshell::Plugins::Discord.new)
  [registry, transport]
end

def configure_poll_accounts(github: true, discord: true)
  if github
    account = GithubAppsAccount.current
    account.update!(app_id: "123", installation_id: "456")
    account.private_key = "fixture-key"
    account.save!
  end
  if discord
    account = DiscordAccount.current
    account.bot_token = "not-a-token"
    account.save!
  end
end

def poll_schedule_job(registry)
  job = IntegrationPollScheduleJob.new
  job.define_singleton_method(:plugin_registry) { registry }
  job
end

def poll_schedule_rows(prior_ids)
  SolidQueue::Job.where(class_name: "InteractionPollJob").where.not(id: prior_ids).order(:id).to_a
end

test("poll scheduler queues each configured concrete scope through the real plugin catalog") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo,github:owner/.github,github:owner/repo,discord:channel/130000000000000001,jira:PROJECT,teams:team/t/channel/c") do
    # Database-backed accounts (presence-only fixtures; not usable
    # credentials). The transport raises if any code accidentally tries to
    # poll while scheduling. Removed plugins (jira/teams) are skipped.
    configure_poll_accounts
    registry, transport = poll_schedule_registry
    # Disabling interaction AI drafting must not stop deterministic ingestion.
    LayerPolicy.create!(layer: "interaction", provider: "codex", enabled: false)
    prior_ids = SolidQueue::Job.where(class_name: "InteractionPollJob").pluck(:id)

    expect(poll_schedule_job(registry).perform_now).to eq(3)

    jobs = poll_schedule_rows(prior_ids)
    expect(jobs.map { |job| job.arguments.fetch("arguments") }).to eq([
      ["github", "owner/repo"], ["github", "owner/.github"],
      ["discord", "channel/130000000000000001"]
    ])
    expect(jobs.all? { |job| job.queue_name == "control" && job.ready_execution.present? }).to eq(true)
    expect(transport.calls).to eq([])
    expect(IntegrationCursor.count).to eq(0)
    expect(ExternalEvent.count).to eq(0)
    expect(TaskRun.count).to eq(0)
  end
end

test("poll scheduler skips wildcards malformed destinations unknown and unconfigured plugins") do |db:|
  scopes = [
    "github:owner/*", "github:*/repo", "github:owner/re?o", "github:owner/[repo]",
    "github:owner/%2A", "github:issue:owner/repo#1", "github:https://github.com/owner/repo",
    "github:owner/..", "github:owner/with space", "github:owner/repo",
    "discord:channel/*", "discord:channel:not-an-id", "discord:channel:130000000000000001",
    "discord:message:130000000000000001/130000000000000002",
    "discord:channel/130000000000000001/extra", "discord:https://discord.com/channels/1/2",
    "discord:channel/130000000000000001",
    "unknown:owner/repo"
  ].join(",")
  with_workflow_env(scopes: scopes) do
    configure_poll_accounts(discord: false)
    registry, transport = poll_schedule_registry
    prior_ids = SolidQueue::Job.where(class_name: "InteractionPollJob").pluck(:id)
    expect(poll_schedule_job(registry).perform_now).to eq(1)
    expect(poll_schedule_rows(prior_ids).map { |job| job.arguments.fetch("arguments") }).to eq([["github", "owner/repo"]])

    # On the next tick the newly configured Discord account becomes
    # eligible, but wildcards and write targets remain barred.
    configure_poll_accounts(github: false, discord: true)
    next_prior_ids = SolidQueue::Job.where(class_name: "InteractionPollJob").pluck(:id)
    expect(poll_schedule_job(registry).perform_now).to eq(2)
    expect(poll_schedule_rows(next_prior_ids).map { |job| job.arguments.fetch("arguments") }).to eq([
      ["github", "owner/repo"], ["discord", "channel/130000000000000001"]
    ])
    expect(transport.calls).to eq([])
  end
end

class PollScheduleUnsupportedPlugin < Aiconshell::Plugins::Base
  plugin_id "github"
  operation "latest_events", input_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_INPUT,
            output_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_OUTPUT,
            unsupported: true, reason: "Fixture capability unavailable"
end

test("poll scheduler honors unsupported operations in the real registry contract") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    registry = Aiconshell::Plugins::Registry.new(env: {}, transport: PollScheduleForbiddenTransport.new)
    registry.register(PollScheduleUnsupportedPlugin.new)
    prior_ids = SolidQueue::Job.where(class_name: "InteractionPollJob").pluck(:id)
    expect(poll_schedule_job(registry).perform_now).to eq(0)
    expect(poll_schedule_rows(prior_ids)).to eq([])
  end
end

class PollScheduleCustomPlugin < Aiconshell::Plugins::Base
  plugin_id "custom"
  required_env "CUSTOM_POLL_TOKEN"
  operation "latest_events", input_schema: {
    "type" => "object",
    "required" => %w[scope],
    "properties" => {
      "scope" => { "type" => "string", "pattern" => '\Aworkspace/[a-z0-9-]+\z' },
      "cursor" => { "type" => %w[object null] }
    },
    "additionalProperties" => false
  }, output_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_OUTPUT

  private

  def handle_latest_events(_input, _context)
    raise "Scheduling must not invoke the custom poll operation"
  end
end

test("poll scheduler accepts registered extensions only for scopes valid against their operation schema") do |db:|
  with_workflow_env(scopes: "custom:workspace/alpha,custom:workspace/beta-2,custom:other/alpha,custom:workspace/*,custom:workspace/,custom:") do
    transport = PollScheduleForbiddenTransport.new
    registry = Aiconshell::Plugins::Registry.new(env: { "CUSTOM_POLL_TOKEN" => "fixture-token" }, transport: transport)
    registry.register(PollScheduleCustomPlugin.new)
    prior_ids = SolidQueue::Job.where(class_name: "InteractionPollJob").pluck(:id)

    expect(poll_schedule_job(registry).perform_now).to eq(2)

    jobs = poll_schedule_rows(prior_ids)
    expect(jobs.map { |job| job.arguments.fetch("arguments") }).to eq([
      ["custom", "workspace/alpha"], ["custom", "workspace/beta-2"]
    ])
    expect(jobs.all? { |job| job.queue_name == "control" && job.ready_execution.present? }).to eq(true)
    expect(transport.calls).to eq([])
  end
end

test("recurring poll scheduler boots from a serialized no-argument Solid Queue job with an empty allowlist") do |db:|
  with_workflow_env(scopes: "") do
    prior_ids = SolidQueue::Job.where(class_name: "InteractionPollJob").pluck(:id)
    enqueued = IntegrationPollScheduleJob.perform_later
    record = SolidQueue::Job.find_by!(active_job_id: enqueued.job_id)
    expect(record.queue_name).to eq("control")
    expect(record.arguments.fetch("arguments")).to eq([])
    expect(ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))).to eq(0)
    expect(poll_schedule_rows(prior_ids)).to eq([])
  end
end
