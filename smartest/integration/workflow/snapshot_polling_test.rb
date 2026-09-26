# frozen_string_literal: true

require "db_helper"
require "aiconshell/plugins"
require "timeout"
require_relative "workflow_test_helper"

# Use the real registry and operation schemas; only the remote response is
# scripted. No transport, external account, or AI provider is invoked.
class SnapshotPollingPlugin < Aiconshell::Plugins::Base
  operation "latest_events", input_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_INPUT,
    output_schema: Aiconshell::Plugins::Schemas::LATEST_EVENTS_OUTPUT, scope: "snapshots:read"

  def initialize(plugin, &response)
    @plugin, @response = plugin, response
  end

  def plugin_id = @plugin
  def handle_latest_events(input, _context) = @response.call(input)
end

def snapshot_event(content, seconds:, type: "github.issue", event_id: "snapshot-1")
  timestamp = (Time.utc(2026, 9, 27) + seconds).iso8601(6)
  {
    "event_id" => event_id, "event_type" => type, "fingerprint" => "semantic-#{content}",
    "resource_id" => "resource:#{event_id}", "actor_id" => "alice", "actor_type" => "human",
    "occurred_at" => timestamp,
    "payload" => { "body" => "Review this issue", "state" => content, "last_modified" => timestamp }
  }
end

def snapshot_poller(events = [], plugin: "github", cursor: { "page" => 1 }, clock: Time, &response)
  response ||= ->(_input) { { "events" => events, "cursor" => cursor } }
  registry = Aiconshell::Plugins::Registry.new(env: {}).register(SnapshotPollingPlugin.new(plugin, &response))
  Interaction::PollService.new(registry: registry, event_sink: WorkflowFakes::FakeEventSink.new, clock: clock)
end

def snapshot_poll(events, plugin: "github", scope: "inbox", **options)
  snapshot_poller(events, plugin: plugin, **options).call(plugin: plugin, scope: scope)
end

test("semantic issue and message snapshots preserve observed content reversions without metadata work") do |db:|
  with_workflow_env(scopes: "github:inbox,jira:inbox,teams:inbox") do
    %w[github.issue jira.issue teams.message teams.reply].each do |type|
      plugin = type.split(".").first
      events = [
        snapshot_event("open", seconds: 0, type: type, event_id: type),
        snapshot_event("open", seconds: 1, type: type, event_id: type),
        snapshot_event("closed", seconds: 2, type: type, event_id: type),
        snapshot_event("open", seconds: 3, type: type, event_id: type)
      ]
      results = events.map { |event| snapshot_poll([event], plugin: plugin) }
      expect(results.all?(&:ok)).to eq(true)
      expect(results.map(&:ingested)).to eq([1, 0, 1, 1])
      rows = ExternalEvent.where(plugin: plugin, event_id: type).order(:id).to_a
      expect(rows.map(&:source_fingerprint)).to eq(%w[semantic-open semantic-closed semantic-open])
      expect(rows.map(&:fingerprint).uniq.size).to eq(3)
      expect(rows.first.occurred_at).to eq(Time.iso8601(events[0]["occurred_at"]))
      expect(rows.first.source_updated_at).to eq(Time.iso8601(events[1]["occurred_at"]))
      expect(rows.first.payload["last_modified"]).to eq(events[0]["occurred_at"])
      expect(snapshot_poll(events, plugin: plugin).ingested).to eq(0)
      expect(ExternalEvent.where(plugin: plugin, event_id: type).count).to eq(3)
    end
  end
end

test("snapshot batches sort each entity chronologically and repeated batches create no revisions") do |db:|
  with_workflow_env(scopes: "github:inbox") do
    first = snapshot_event("open", seconds: 0)
    metadata = snapshot_event("open", seconds: 1)
    closed = snapshot_event("closed", seconds: 2)
    reopened = snapshot_event("open", seconds: 3)
    batch = [reopened, closed, first, metadata, reopened, first, closed]

    expect(snapshot_poll(batch).ingested).to eq(3)
    expect(ExternalEvent.order(:id).pluck(:source_fingerprint)).to eq(%w[semantic-open semantic-closed semantic-open])
    expect(ExternalEvent.order(:id).pluck(:occurred_at)).to eq([0, 2, 3].map { |seconds| Time.utc(2026, 9, 27) + seconds })
    expect(snapshot_poll(batch).ingested).to eq(0)
    expect(IntegrationCursor.first.cursor).to eq({ "page" => 1 })
  end
end

test("metadata-only observations reject delayed older content even after retry through another scope") do |db:|
  with_workflow_env(scopes: "github:inbox,github:overlap") do
    expect(snapshot_poll([snapshot_event("open", seconds: 2)]).ingested).to eq(1)
    expect(snapshot_poll([snapshot_event("open", seconds: 4)]).ingested).to eq(0)
    stale = snapshot_event("closed", seconds: 3)
    expect(snapshot_poll([stale], scope: "overlap").ingested).to eq(0)
    expect(ExternalEvent.count).to eq(1)
    expect(ExternalEvent.first.source_updated_at).to eq(Time.utc(2026, 9, 27) + 4)
    expect(snapshot_poll([snapshot_event("closed", seconds: 5)]).ingested).to eq(1)
    expect(snapshot_poll([snapshot_event("open", seconds: 4)]).ingested).to eq(0)
    expect(ExternalEvent.order(:id).last.source_fingerprint).to eq("semantic-closed")
  end
end

test("conflicting snapshots tied at database timestamp precision keep the first observation") do |db:|
  with_workflow_env(scopes: "github:inbox") do
    first = snapshot_event("open", seconds: 0)
    other = snapshot_event("closed", seconds: 0)
    first["occurred_at"] = "2026-09-27T00:00:00.0000001Z"
    other["occurred_at"] = "2026-09-27T00:00:00.0000009Z"
    expect(snapshot_poll([first, other]).ingested).to eq(1)
    expect(snapshot_poll([other, first]).ingested).to eq(0)
    expect(ExternalEvent.first.source_fingerprint).to eq("semantic-open")
    expect(ExternalEvent.first.source_updated_at).to eq(Time.utc(2026, 9, 27))
  end
end

test("comment change and workflow events keep original global fingerprint deduplication") do |db:|
  with_workflow_env(scopes: "github:inbox,jira:inbox") do
    %w[github.issue_comment github.pull_review github.review_comment github.workflow_run jira.comment jira.change].each do |type|
      plugin = type.split(".").first
      original = snapshot_event("first", seconds: 3, type: type, event_id: type)
      older = snapshot_event("older", seconds: 1, type: type, event_id: type)
      expect(snapshot_poll([original], plugin: plugin).ingested).to eq(1)
      expect(snapshot_poll([older, original], plugin: plugin).ingested).to eq(1)
      rows = ExternalEvent.where(plugin: plugin, event_id: type).order(:id).to_a
      expect(rows.map(&:fingerprint)).to eq(%w[semantic-first semantic-older])
      expect(rows.map(&:source_fingerprint)).to eq([nil, nil])
      expect(rows.map(&:source_updated_at)).to eq([nil, nil])
    end
  end
end

test("a rejected snapshot insert rolls back prior metadata and cursor changes") do |db:|
  with_workflow_env(scopes: "github:inbox") do
    snapshot_poll([snapshot_event("open", seconds: 0)], cursor: { "page" => 1 })
    db.execute("ALTER TABLE external_events ADD CONSTRAINT reject_snapshot_fixture CHECK (source_fingerprint <> 'semantic-reject')")
    result = snapshot_poll([
      snapshot_event("open", seconds: 1), snapshot_event("reject", seconds: 2)
    ], cursor: { "page" => 2 })

    expect(result.code).to eq(:plugin_error)
    expect(ExternalEvent.count).to eq(1)
    expect(ExternalEvent.first.source_updated_at).to eq(Time.utc(2026, 9, 27))
    expect(IntegrationCursor.first.cursor).to eq({ "page" => 1 })
    expect(IntegrationCursor.first.lease_token).to eq(nil)
    expect(db.select_value("SELECT 1")).to eq(1)
  end
end

test("simultaneous PostgreSQL polls through overlapping scopes persist each revision once") do
  # No enclosing fixture transaction: both connections need committed rows.
  suffix = SecureRandom.hex(8)
  scopes = ["snapshots-a-#{suffix}", "snapshots-b-#{suffix}"]
  event_ids = ["source-a-#{suffix}", "source-b-#{suffix}"]
  with_workflow_env(scopes: scopes.map { |scope| "github:#{scope}" }.join(",")) do
    events = event_ids.flat_map do |event_id|
      [snapshot_event("open", seconds: 0, event_id: event_id),
       snapshot_event("closed", seconds: 1, event_id: event_id),
       snapshot_event("open", seconds: 2, event_id: event_id)]
    end
    ready, release = Queue.new, Queue.new
    workers = scopes.each_with_index.map do |scope, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          poller = snapshot_poller do |_input|
            raise "Plugin invoked inside a transaction" if connection.transaction_open?
            ready << true
            release.pop
            { "events" => index.zero? ? events : events.reverse, "cursor" => { "page" => 2 } }
          end
          poller.call(plugin: "github", scope: scope)
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { release << true }
    workers.each { |worker| raise "Concurrent poll timed out" unless worker.join(10) }
    results = workers.map(&:value)
    expect(results.all?(&:ok)).to eq(true)
    expect(results.map(&:ingested).sum).to eq(6)
    event_ids.each do |event_id|
      rows = ExternalEvent.where(plugin: "github", event_id: event_id).order(:id)
      expect(rows.pluck(:source_fingerprint)).to eq(%w[semantic-open semantic-closed semantic-open])
      expect(rows.pluck(:fingerprint).uniq.size).to eq(3)
    end
    expect(IntegrationCursor.where(plugin: "github", scope: scopes).pluck(:cursor)).to eq([{ "page" => 2 }, { "page" => 2 }])
  ensure
    workers&.each { |worker| worker.kill if worker.alive?; worker.join }
    ExternalEvent.where(plugin: "github", event_id: event_ids).delete_all
    IntegrationCursor.where(plugin: "github", scope: scopes).delete_all
  end
end

test("a cursor lease expiring during a PostgreSQL snapshot lock wait rolls back ingestion") do
  suffix = SecureRandom.hex(8)
  scopes = ["snapshot-seed-#{suffix}", "snapshot-wait-#{suffix}"]
  event_id = "source-#{suffix}"
  with_workflow_env(scopes: scopes.map { |scope| "github:#{scope}" }.join(",")) do
    clock = Struct.new(:current).new(Time.current)
    snapshot_poll([snapshot_event("open", seconds: 0, event_id: event_id)], scope: scopes.first)
    row = ExternalEvent.find_by!(plugin: "github", event_id: event_id)
    ready = Queue.new
    worker = nil
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.transaction do
        row.lock!
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |poll_connection|
            poller = snapshot_poller(clock: clock) do |_input|
              raise "Plugin invoked inside a transaction" if poll_connection.transaction_open?
              ready << poll_connection.select_value("SELECT pg_backend_pid()")
              { "events" => [snapshot_event("open", seconds: 1, event_id: event_id),
                snapshot_event("closed", seconds: 2, event_id: event_id)], "cursor" => { "page" => 2 } }
            end
            poller.call(plugin: "github", scope: scopes.last)
          end
        end
        Timeout.timeout(10) do
          pid = Integer(ready.pop)
          loop do
            connection.execute("SELECT pg_stat_clear_snapshot()")
            break if connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{pid}") == "Lock"
            sleep 0.01
          end
        end
        clock.current += WorkflowSettings.poll_lease_seconds + 1
      end
    end
    raise "Waiting poll timed out" unless worker.join(10)
    expect(worker.value.code).to eq(:stale_poll)
    expect(ExternalEvent.where(plugin: "github", event_id: event_id).count).to eq(1)
    expect(row.reload.source_updated_at).to eq(Time.utc(2026, 9, 27))
    expect(IntegrationCursor.find_by!(plugin: "github", scope: scopes.last).cursor).to eq(nil)
  ensure
    if worker
      worker.kill if worker.alive?
      worker.join
    end
    ExternalEvent.where(plugin: "github", event_id: event_id).delete_all
    IntegrationCursor.where(plugin: "github", scope: scopes).delete_all
  end
end
