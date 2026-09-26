# frozen_string_literal: true

require "aiconshell/observability" unless defined?(Aiconshell::Observability)

module EventLogging
  # ActiveRecord implementation of the Aiconshell::Observability::Outbox
  # port. Used by the Rails delivery job; the standalone pg implementation
  # lives in lib for pre-Rails and script use.
  class OutboxAdapter
    include Aiconshell::Observability::Outbox

    def enqueue(envelope, teams_channel: nil)
      record = begin
        EventDelivery.create!(
          event_id: envelope.fetch("event_id"),
          envelope:,
          layer: envelope["layer"],
          kind: envelope["kind"],
          task_id: envelope["task_id"],
          correlation_id: envelope["correlation_id"],
          occurred_at: envelope["occurred_at"],
          teams_channel:
        )
      rescue ActiveRecord::RecordNotUnique
        EventDelivery.find_by!(event_id: envelope.fetch("event_id"))
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.errors[:event_id].include?("has already been taken")

        EventDelivery.find_by!(event_id: envelope.fetch("event_id"))
      end
      to_record(record)
    end

    def pending(destination, limit:, now:)
      scope = case Aiconshell::Observability::Outbox.destination!(destination)
              when "clickhouse" then EventDelivery.clickhouse_pending(now)
              when "teams" then EventDelivery.teams_pending(now)
              end
      scope.limit(limit).map { |record| to_record(record) }
    end

    def mark_delivered(id, destination, at:)
      destination = Aiconshell::Observability::Outbox.destination!(destination)
      EventDelivery.where(id:).update_all(
        "#{destination}_delivered_at" => at,
        "#{destination}_next_retry_at" => nil,
        updated_at: Time.current
      )
    end

    def mark_failed(id, destination, error:, next_retry_at:)
      destination = Aiconshell::Observability::Outbox.destination!(destination)
      EventDelivery.where(id:).update_all(
        "#{destination}_attempts" => EventDelivery.arel_table["#{destination}_attempts"] + 1,
        "#{destination}_last_error" => error.to_s,
        "#{destination}_next_retry_at" => next_retry_at,
        updated_at: Time.current
      )
    end

    def mark_skipped(id, destination, reason:, at:)
      destination = Aiconshell::Observability::Outbox.destination!(destination)
      EventDelivery.where(id:).update_all(
        "#{destination}_skipped_at" => at,
        "#{destination}_last_error" => reason.to_s,
        "#{destination}_next_retry_at" => nil,
        updated_at: Time.current
      )
    end

    def prune(before:)
      EventDelivery.prunable(before).delete_all
    end

    def find_by_event_id(event_id)
      record = EventDelivery.find_by(event_id:)
      record && to_record(record)
    end

    private

    def to_record(record)
      {
        "id" => record.id,
        "event_id" => record.event_id,
        "envelope" => record.envelope,
        "teams_channel" => record.teams_channel,
        "clickhouse" => destination_state(record, "clickhouse"),
        "teams" => destination_state(record, "teams"),
        "created_at" => record.created_at
      }
    end

    def destination_state(record, destination)
      {
        "delivered_at" => record.public_send("#{destination}_delivered_at"),
        "skipped_at" => record.public_send("#{destination}_skipped_at"),
        "attempts" => record.public_send("#{destination}_attempts").to_i,
        "next_retry_at" => record.public_send("#{destination}_next_retry_at"),
        "last_error" => record.public_send("#{destination}_last_error")
      }
    end
  end
end
