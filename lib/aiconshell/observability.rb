# frozen_string_literal: true

require "logger"
require_relative "observability/redaction"
require_relative "observability/envelope"
require_relative "observability/outbox"
require_relative "observability/clickhouse_adapter"
require_relative "observability/teams_sink"
require_relative "observability/delivery_service"

# NOTE: lib/aiconshell/observability/postgres_outbox.rb is intentionally not
# required here: it needs the `pg` gem and a live database. Consumers that
# drain a PostgreSQL spool without Rails require it explicitly:
#   require "aiconshell/observability/postgres_outbox"

module Aiconshell
  # EventLog port (docs/architecture.md contract). emit writes a redacted,
  # validated envelope to the outbox spool without touching the network, so
  # logging can never roll back the surrounding business update. Delivery to
  # ClickHouse / Teams happens asynchronously via DeliveryService.
  module Observability
    class Config
      attr_accessor :outbox, :search_backend, :logger, :clock

      def initialize
        @outbox = MemoryOutbox.new
        @search_backend = nil
        @logger = Logger.new(File::NULL)
        @clock = Time
      end
    end

    @config = Config.new
    @config_mutex = Mutex.new

    class << self
      def configure
        @config_mutex.synchronize { yield @config }
      end

      def config
        @config
      end

      # Test helper: restores defaults (fresh memory outbox, null logger).
      def reset!
        @config_mutex.synchronize { @config = Config.new }
      end

      # Never raises: validation, outbox, and redaction failures are logged
      # (sanitized) and reported as nil so business transactions survive.
      def emit(layer:, kind:, message:, task_id: nil, correlation_id: nil,
               data: {}, event_id: nil, occurred_at: nil, teams_channel: nil)
        emit!(layer:, kind:, message:, task_id:, correlation_id:, data:,
              event_id:, occurred_at:, teams_channel:)
      rescue StandardError => e
        begin
          config.logger.warn("observability emit dropped: #{Redaction.sanitize_error(e)}")
        rescue StandardError
          # A broken log destination must not turn best-effort telemetry
          # into a failure of the surrounding business operation.
        end
        nil
      end

      # Strict variant: raises ValidationError on bad input. Still performs
      # no network I/O; delivery stays asynchronous.
      def emit!(layer:, kind:, message:, task_id: nil, correlation_id: nil,
                data: {}, event_id: nil, occurred_at: nil, teams_channel: nil)
        envelope = Envelope.build(
          layer:, kind:, message:, task_id:, correlation_id:, data:,
          event_id:, occurred_at:, clock: config.clock
        )
        config.outbox.enqueue(envelope, teams_channel:)
        envelope
      end

      def search(query: nil, layer: nil, kind: nil, task_id: nil,
                 correlation_id: nil, event_id: nil,
                 since: nil, until_time: nil, limit: 100)
        backend = config.search_backend
        raise NotConfiguredError, "observability search_backend is not configured" if backend.nil?

        backend.search(query:, layer:, kind:, task_id:, correlation_id:,
                       event_id:, since:, until_time:, limit:)
      end
    end
  end
end
