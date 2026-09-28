# frozen_string_literal: true

require "json"
require "pg"
require_relative "../observability"

module Aiconshell
  module Observability
    # PostgreSQL-backed Outbox over a `pg` connection. Standalone-capable:
    # no Rails or ActiveRecord required. The table must exist (see
    # db/migrate/*_create_event_deliveries.rb); all statements are
    # parameterized.
    class PostgresOutbox
      include Outbox

      COLUMNS = %w[
        id event_id envelope layer kind task_id correlation_id occurred_at
        clickhouse_delivered_at clickhouse_attempts clickhouse_next_retry_at clickhouse_last_error clickhouse_skipped_at
        created_at updated_at
      ].freeze

      def initialize(connection)
        @connection = connection
      end

      def enqueue(envelope)
        params = [
          envelope.fetch("event_id"), JSON.generate(envelope),
          envelope["layer"], envelope["kind"], envelope["task_id"],
          envelope["correlation_id"], envelope["occurred_at"]
        ]
        @connection.exec_params(<<~SQL, params)
          INSERT INTO event_deliveries
            (event_id, envelope, layer, kind, task_id, correlation_id, occurred_at,
             created_at, updated_at)
          VALUES ($1, $2::jsonb, $3, $4, $5, $6, $7::timestamptz, NOW(), NOW())
          ON CONFLICT (event_id) DO NOTHING
        SQL
        find_by_event_id(envelope.fetch("event_id"))
      end

      def pending(destination, limit:, now:)
        destination = Outbox.destination!(destination)
        rows = @connection.exec_params(<<~SQL, [now.utc.iso8601(3), limit]).to_a
          SELECT #{COLUMNS.join(", ")}
          FROM event_deliveries
          WHERE #{destination}_delivered_at IS NULL
            AND #{destination}_skipped_at IS NULL
            AND (#{destination}_next_retry_at IS NULL OR #{destination}_next_retry_at <= $1::timestamptz)
          ORDER BY id ASC
          LIMIT $2
        SQL
        rows.map { |row| to_record(row) }
      end

      def mark_delivered(id, destination, at:)
        destination = Outbox.destination!(destination)
        result = @connection.exec_params(<<~SQL, [at.utc.iso8601(3), id])
          UPDATE event_deliveries
          SET #{destination}_delivered_at = $1::timestamptz,
              #{destination}_next_retry_at = NULL,
              updated_at = NOW()
          WHERE id = $2
        SQL
        raise ArgumentError, "unknown outbox record #{id}" if result.cmd_tuples.zero?
      end

      def mark_failed(id, destination, error:, next_retry_at:)
        destination = Outbox.destination!(destination)
        result = @connection.exec_params(<<~SQL, [error.to_s, next_retry_at.utc.iso8601(3), id])
          UPDATE event_deliveries
          SET #{destination}_attempts = #{destination}_attempts + 1,
              #{destination}_last_error = $1,
              #{destination}_next_retry_at = $2::timestamptz,
              updated_at = NOW()
          WHERE id = $3
        SQL
        raise ArgumentError, "unknown outbox record #{id}" if result.cmd_tuples.zero?
      end

      def mark_skipped(id, destination, reason:, at:)
        destination = Outbox.destination!(destination)
        result = @connection.exec_params(<<~SQL, [reason.to_s, at.utc.iso8601(3), id])
          UPDATE event_deliveries
          SET #{destination}_skipped_at = $2::timestamptz,
              #{destination}_last_error = $1,
              #{destination}_next_retry_at = NULL,
              updated_at = NOW()
          WHERE id = $3
        SQL
        raise ArgumentError, "unknown outbox record #{id}" if result.cmd_tuples.zero?
      end

      def prune(before:)
        result = @connection.exec_params(<<~SQL, [before.utc.iso8601(3)])
          DELETE FROM event_deliveries
          WHERE created_at < $1::timestamptz
            AND (clickhouse_delivered_at IS NOT NULL OR clickhouse_skipped_at IS NOT NULL)
        SQL
        result.cmd_tuples
      end

      def find_by_event_id(event_id)
        rows = @connection.exec_params(<<~SQL, [event_id]).to_a
          SELECT #{COLUMNS.join(", ")} FROM event_deliveries WHERE event_id = $1 LIMIT 1
        SQL
        rows.empty? ? nil : to_record(rows.first)
      end

      private

      def to_record(row)
        {
          "id" => row["id"].to_i,
          "event_id" => row["event_id"],
          "envelope" => JSON.parse(row["envelope"].to_s),
          "clickhouse" => destination_state(row, "clickhouse"),
          "created_at" => parse_time(row["created_at"])
        }
      end

      def destination_state(row, destination)
        {
          "delivered_at" => parse_time(row["#{destination}_delivered_at"]),
          "skipped_at" => parse_time(row["#{destination}_skipped_at"]),
          "attempts" => row["#{destination}_attempts"].to_i,
          "next_retry_at" => parse_time(row["#{destination}_next_retry_at"]),
          "last_error" => row["#{destination}_last_error"]
        }
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.empty?

        Time.parse(value.to_s).utc
      end
    end
  end
end
