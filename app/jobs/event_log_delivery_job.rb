# frozen_string_literal: true

# Drains the EventDelivery outbox spool to ClickHouse / Teams and prunes
# delivered rows. Scheduled as a recurring control-queue task (see
# docs/event-log.md). Run one at a time: the delivery itself is idempotent,
# but concurrent runs waste Teams posts on crash replays.
class EventLogDeliveryJob < ApplicationJob
  queue_as :control

  def perform(batch_size: 100, prune_retention_days: 7)
    summary = EventLogging::Delivery.deliver_pending(batch_size:)
    pruned = EventLogging::Delivery.prune(retention_days: prune_retention_days)
    logger.info(
      "event_log delivery clickhouse=#{summary.clickhouse.inspect} " \
      "teams=#{summary.teams.inspect} pruned=#{pruned}"
    )
    summary.to_h.merge("pruned" => pruned)
  end
end
