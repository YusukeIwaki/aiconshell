# frozen_string_literal: true

require "integration/observability_helper"

test("delivery job is serialized to one run at a time") do |db:, observability_config:|
  expect(EventLogDeliveryJob.queue_name).to eq("control")
  expect(EventLogDeliveryJob.concurrency_limit).to eq(1)
  expect(EventLogDeliveryJob.new.concurrency_limited?).to eq(true)
  expect(EventLogDeliveryJob.concurrency_on_conflict).to eq(:block)
end

test("delivery job drains the spool and reports counts") do |db:, observability_config:|
  saved_url = ENV["CLICKHOUSE_URL"]
  begin
    ENV.delete("CLICKHOUSE_URL") # rows stay pending for ClickHouse
    EventLogging::OutboxAdapter.new.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")

    result = EventLogDeliveryJob.new.perform(batch_size: 10, prune_retention_days: 7)

    expect(result["teams"]).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 1 })
    expect(result["clickhouse"]).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 0 })
    expect(result["pruned"]).to eq(0)
  ensure
    saved_url.nil? ? ENV.delete("CLICKHOUSE_URL") : ENV.store("CLICKHOUSE_URL", saved_url)
  end
end
