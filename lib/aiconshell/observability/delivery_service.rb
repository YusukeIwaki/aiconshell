# frozen_string_literal: true

require "logger"

module Aiconshell
  module Observability
    # Drains the outbox spool into ClickHouse with per-destination retry
    # state. A failure listing, inserting, or even marking rows is counted
    # and logged while the summary stays accurate.
    #
    # Retries are bounded: after MAX_ATTEMPTS failures a row is marked
    # skipped (terminal, prunable) instead of retrying forever, so a
    # months-long outage cannot grow the spool without bound.
    #
    # Exactly-once is not promised: a crash between a successful sink call
    # and the delivered mark re-delivers. ClickHouse collapses replays by
    # event_id (ReplacingMergeTree + FINAL reads).
    #
    # The service never emits events itself: all diagnostics go to the
    # injected logger, so a sink outage cannot recurse into the outbox.
    class DeliveryService
      DEFAULT_BATCH_SIZE = 100
      DEFAULT_RETENTION_DAYS = 7
      RETRY_BASE_SECONDS = 120
      RETRY_MAX_SECONDS = 21_600
      MAX_ATTEMPTS = 25

      Summary = Struct.new(:clickhouse, :error, keyword_init: true) do
        def to_h
          { "clickhouse" => clickhouse, "error" => error }
        end
      end

      def initialize(outbox:, clickhouse: nil,
                     logger: Logger.new(File::NULL), clock: Time)
        @outbox = outbox
        @clickhouse = clickhouse
        @logger = logger
        @clock = clock
      end

      def deliver_pending(batch_size: DEFAULT_BATCH_SIZE)
        clickhouse_counts, clickhouse_error = isolated("clickhouse") { deliver_clickhouse(batch_size:) }
        Summary.new(clickhouse: clickhouse_counts, error: clickhouse_error)
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
        counts = zero_counts
        if @clickhouse.nil?
          @logger.error("event_log clickhouse sink unconfigured; leaving outbox rows pending")
          return counts
        end

        records = @outbox.pending("clickhouse", limit: batch_size, now: now)
        return counts if records.empty?

        begin
          @clickhouse.insert(records.map { |record| record["envelope"] })
        rescue StandardError => e
          message = Redaction.sanitize_error(e)
          @logger.warn("event_log clickhouse batch failed: #{message}")
          records.each { |record| fail_record(record, "clickhouse", message, counts) }
          return counts
        end

        records.each { |record| mark_delivered_guarded(record, "clickhouse", counts) }
        counts
      end

      # Runs the sink, converting an unexpected raise (e.g. pending listing
      # blew up) into zero counts plus an error string so the summary stays
      # accurate.
      def isolated(destination)
        [yield, nil]
      rescue StandardError => e
        message = Redaction.sanitize_error(e)
        @logger.error("event_log #{destination} delivery run failed: #{message}")
        [zero_counts, "#{destination}: #{message}"]
      end

      def zero_counts
        { "delivered" => 0, "failed" => 0, "skipped" => 0 }
      end

      def mark_delivered_guarded(record, destination, counts)
        @outbox.mark_delivered(record["id"], destination, at: now)
        counts["delivered"] += 1
      rescue StandardError => e
        @logger.warn("event_log #{destination} delivered-mark failed: #{Redaction.sanitize_error(e)}")
        counts["failed"] += 1
      end

      def mark_skipped_guarded(record, destination, reason, counts)
        @outbox.mark_skipped(record["id"], destination, reason:, at: now)
        counts["skipped"] += 1
      rescue StandardError => e
        @logger.warn("event_log #{destination} skipped-mark failed: #{Redaction.sanitize_error(e)}")
        counts["failed"] += 1
      end

      def fail_record(record, destination, message, counts)
        attempts = record[destination]["attempts"].to_i + 1
        if attempts >= MAX_ATTEMPTS
          @outbox.mark_skipped(record["id"], destination,
                               reason: "gave up after #{attempts} attempts: #{message}", at: now)
          counts["skipped"] += 1
        else
          delay = self.class.retry_delay_seconds(attempts)
          @outbox.mark_failed(record["id"], destination, error: message, next_retry_at: now + delay)
          counts["failed"] += 1
        end
      rescue StandardError => e
        @logger.warn("event_log #{destination} state update failed: #{Redaction.sanitize_error(e)}")
        counts["failed"] += 1
      end
    end
  end
end
