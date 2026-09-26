# frozen_string_literal: true

require "logger"

module Aiconshell
  module Observability
    # Drains the outbox spool into ClickHouse and Teams with independent
    # per-destination retry state. A Teams failure never re-sends to
    # ClickHouse; a ClickHouse failure never blocks Teams.
    #
    # Exactly-once is not promised: a crash between a successful sink call
    # and the delivered mark re-delivers. ClickHouse collapses replays by
    # event_id (ReplacingMergeTree + FINAL reads); Teams has no provider
    # idempotency, so replays may double-post.
    #
    # The service never emits events itself: all diagnostics go to the
    # injected logger, so a sink outage cannot recurse into the outbox.
    class DeliveryService
      DEFAULT_BATCH_SIZE = 100
      DEFAULT_RETENTION_DAYS = 7
      RETRY_BASE_SECONDS = 120
      RETRY_MAX_SECONDS = 21_600

      Summary = Struct.new(:clickhouse, :teams, :error, keyword_init: true) do
        def to_h
          { "clickhouse" => clickhouse, "teams" => teams, "error" => error }
        end
      end

      def initialize(outbox:, clickhouse: nil, teams: nil,
                     logger: Logger.new(File::NULL), clock: Time)
        @outbox = outbox
        @clickhouse = clickhouse
        @teams = teams
        @logger = logger
        @clock = clock
      end

      def deliver_pending(batch_size: DEFAULT_BATCH_SIZE)
        clickhouse_counts = deliver_clickhouse(batch_size:)
        teams_counts = deliver_teams(batch_size:)
        Summary.new(clickhouse: clickhouse_counts, teams: teams_counts, error: nil)
      rescue StandardError => e
        message = Redaction.sanitize_error(e)
        @logger.error("event_log delivery run failed: #{message}")
        Summary.new(clickhouse: { "delivered" => 0, "failed" => 0, "skipped" => 0 },
                    teams: { "delivered" => 0, "failed" => 0, "skipped" => 0 },
                    error: message)
      end

      def prune(retention_days: DEFAULT_RETENTION_DAYS)
        @outbox.prune(before: @clock.now.utc - retention_days * 86_400)
      end

      def self.retry_delay_seconds(attempts, base: RETRY_BASE_SECONDS, max: RETRY_MAX_SECONDS)
        [base * (2**(attempts - 1)), max].min
      end

      private

      def now
        @clock.now.utc
      end

      def deliver_clickhouse(batch_size:)
        counts = { "delivered" => 0, "failed" => 0, "skipped" => 0 }
        if @clickhouse.nil?
          @logger.error("event_log clickhouse sink unconfigured; leaving outbox rows pending")
          return counts
        end

        records = @outbox.pending("clickhouse", limit: batch_size, now: now)
        return counts if records.empty?

        @clickhouse.insert(records.map { |record| record["envelope"] })
        records.each { |record| @outbox.mark_delivered(record["id"], "clickhouse", at: now) }
        counts["delivered"] = records.size
        counts
      rescue StandardError => e
        message = Redaction.sanitize_error(e)
        @logger.warn("event_log clickhouse batch failed: #{message}")
        records.each { |record| fail_record(record, "clickhouse", message) }
        counts["failed"] = records.size
        counts
      end

      def deliver_teams(batch_size:)
        counts = { "delivered" => 0, "failed" => 0, "skipped" => 0 }
        records = @outbox.pending("teams", limit: batch_size, now: now)
        return counts if records.empty?

        if @teams.nil? || !@teams.enabled?
          reason = "teams sink disabled"
          records.each { |record| @outbox.mark_skipped(record["id"], "teams", reason:, at: now) }
          counts["skipped"] = records.size
          return counts
        end

        records.each do |record|
          begin
            outcome = @teams.deliver(record)
            if outcome == :delivered
              @outbox.mark_delivered(record["id"], "teams", at: now)
              counts["delivered"] += 1
            else
              @outbox.mark_skipped(record["id"], "teams", reason: "teams sink skipped", at: now)
              counts["skipped"] += 1
            end
          rescue StandardError => e
            message = Redaction.sanitize_error(e)
            @logger.warn("event_log teams delivery failed: #{message}")
            fail_record(record, "teams", message)
            counts["failed"] += 1
          end
        end
        counts
      end

      def fail_record(record, destination, message)
        attempts = record[destination]["attempts"].to_i + 1
        delay = self.class.retry_delay_seconds(attempts)
        @outbox.mark_failed(record["id"], destination, error: message, next_retry_at: now + delay)
      end
    end
  end
end
