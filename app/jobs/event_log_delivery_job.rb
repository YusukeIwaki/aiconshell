# frozen_string_literal: true

# Drains the EventDelivery outbox spool to ClickHouse / Teams and prunes
# delivered rows. Scheduled as a recurring control-queue task (see
# docs/event-log.md). Serialized to one run at a time via Solid Queue: the
# ClickHouse half is idempotent, but concurrent runs could double-post
# Teams. Conflicting runs block (reschedule) rather than discard, so every
# tick still drains. A crash between a Teams post and its delivered mark
# can still double-post on redelivery; Teams is notification, not record.
class EventLogDeliveryJob < ApplicationJob
  queue_as :control

  limits_concurrency key: "event_log_delivery", to: 1,
                     duration: 10.minutes, on_conflict: :block

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
