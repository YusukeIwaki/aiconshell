# frozen_string_literal: true

# Drains the EventDelivery outbox spool to ClickHouse and prunes delivered
# rows. Scheduled as a recurring control-queue task (see docs/event-log.md).
# Serialized to one run at a time via Solid Queue: the ClickHouse sink is
# idempotent, but serialization keeps batch accounting stable. Conflicting
# runs block (reschedule) rather than discard, so every tick still drains.
# A session advisory lock also guards runs that outlive the queue
# semaphore's duration.
class EventLogDeliveryJob < ApplicationJob
  queue_as :control

  limits_concurrency key: "event_log_delivery", to: 1,
                     duration: 10.minutes, on_conflict: :block

  def perform(batch_size: 100, prune_retention_days: 7)
    EventLogging::DeliveryLock.with_lock do
      summary = EventLogging::Delivery.deliver_pending(batch_size:)
      pruned = EventLogging::Delivery.prune(retention_days: prune_retention_days)
      logger.info(
        "event_log delivery clickhouse=#{summary.clickhouse.inspect} pruned=#{pruned}"
      )
      summary.to_h.merge("pruned" => pruned)
    end
  end
end
