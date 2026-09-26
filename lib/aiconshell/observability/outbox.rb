# frozen_string_literal: true

require "monitor"

module Aiconshell
  module Observability
    # Outbox port: PostgreSQL-backed spool of not-yet-delivered events.
    #
    # The outbox is a delivery spool, not a log archive. Each record carries
    # one redacted envelope plus independent per-destination delivery state
    # ("clickhouse", "teams"), so a Teams failure never re-sends to
    # ClickHouse and a ClickHouse failure never blocks Teams.
    #
    # Record shape (String keys; times are Time in UTC or nil):
    #   { "id", "event_id", "envelope", "teams_channel",
    #     "clickhouse" => { "delivered_at", "attempts", "next_retry_at", "last_error" },
    #     "teams" => { ...same, plus "skipped_at" }, "created_at" }
    module Outbox
      DESTINATIONS = %w[clickhouse teams].freeze

      def enqueue(_envelope, teams_channel: nil)
        raise NotImplementedError
      end

      def pending(_destination, limit:, now:)
        raise NotImplementedError
      end

      def mark_delivered(_id, _destination, at:)
        raise NotImplementedError
      end

      def mark_failed(_id, _destination, error:, next_retry_at:)
        raise NotImplementedError
      end

      def mark_skipped(_id, _destination, reason:, at:)
        raise NotImplementedError
      end

      def prune(before:)
        raise NotImplementedError
      end

      def find_by_event_id(_event_id)
        raise NotImplementedError
      end

      def self.destination!(destination)
        raise ArgumentError, "unknown destination #{destination.inspect}" unless DESTINATIONS.include?(destination.to_s)

        destination.to_s
      end

      def self.delivered?(state)
        !state["delivered_at"].nil?
      end

      def self.skipped?(state)
        !state["skipped_at"].nil?
      end

      def self.terminal?(state)
        delivered?(state) || skipped?(state)
      end

      def self.due?(state, now)
        return false if terminal?(state)

        state["next_retry_at"].nil? || state["next_retry_at"] <= now
      end
    end

    # In-memory Outbox used for unit tests and as the pre-Rails default.
    # Never use in production: contents vanish on restart (see docs).
    class MemoryOutbox
      include Outbox

      def initialize(clock: Time)
        @clock = clock
        @monitor = Monitor.new
        @records = []
        @sequence = 0
      end

      def enqueue(envelope, teams_channel: nil)
        @monitor.synchronize do
          existing = @records.find { |record| record["event_id"] == envelope["event_id"] }
          return deep_dup(existing) if existing

          @sequence += 1
          record = {
            "id" => @sequence,
            "event_id" => envelope.fetch("event_id"),
            "envelope" => deep_dup(envelope),
            "teams_channel" => teams_channel,
            "clickhouse" => fresh_state,
            "teams" => fresh_state,
            "created_at" => @clock.now.utc
          }
          @records << record
          deep_dup(record)
        end
      end

      def pending(destination, limit:, now:)
        destination = Outbox.destination!(destination)
        @monitor.synchronize do
          selected = @records.select do |record|
            next false if destination == "teams" && (record["teams_channel"].nil? || record["teams_channel"].empty?)

            Outbox.due?(record[destination], now)
          end
          selected.sort_by { |record| record["id"] }.first(limit).map { |record| deep_dup(record) }
        end
      end

      def mark_delivered(id, destination, at:)
        mutate(id, destination) do |state|
          state["delivered_at"] = at
          state["next_retry_at"] = nil
        end
      end

      def mark_failed(id, destination, error:, next_retry_at:)
        mutate(id, destination) do |state|
          state["attempts"] += 1
          state["last_error"] = error
          state["next_retry_at"] = next_retry_at
        end
      end

      def mark_skipped(id, destination, reason:, at:)
        mutate(id, destination) do |state|
          state["skipped_at"] = at
          state["last_error"] = reason
          state["next_retry_at"] = nil
        end
      end

      def prune(before:)
        @monitor.synchronize do
          before_count = @records.size
          @records.reject! do |record|
            record["created_at"] < before &&
              Outbox.terminal?(record["clickhouse"]) &&
              teams_terminal_or_unrequested?(record)
          end
          before_count - @records.size
        end
      end

      def find_by_event_id(event_id)
        @monitor.synchronize do
          record = @records.find { |entry| entry["event_id"] == event_id }
          record && deep_dup(record)
        end
      end

      def size
        @monitor.synchronize { @records.size }
      end

      def clear
        @monitor.synchronize do
          @records.clear
          @sequence = 0
        end
      end

      private

      def fresh_state
        { "delivered_at" => nil, "skipped_at" => nil, "attempts" => 0,
          "next_retry_at" => nil, "last_error" => nil }
      end

      def teams_terminal_or_unrequested?(record)
        channel = record["teams_channel"]
        return true if channel.nil? || channel.empty?

        Outbox.terminal?(record["teams"])
      end

      def mutate(id, destination)
        destination = Outbox.destination!(destination)
        @monitor.synchronize do
          record = @records.find { |entry| entry["id"] == id }
          raise ArgumentError, "unknown outbox record #{id}" unless record

          yield record[destination]
          deep_dup(record)
        end
      end

      def deep_dup(value)
        case value
        when Hash then value.each_with_object({}) { |(k, v), out| out[k] = deep_dup(v) }
        when Array then value.map { |entry| deep_dup(entry) }
        else
          begin
            value.dup
          rescue TypeError
            value
          end
        end
      end
    end
  end
end
