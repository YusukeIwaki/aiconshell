# frozen_string_literal: true

require "logger"
require "aiconshell/observability" unless defined?(Aiconshell::Observability)

module EventLogging
  # Rails wiring for asynchronous delivery: ActiveRecord outbox, ClickHouse
  # adapter from ENV, Teams sink through the plugins port. Called by
  # EventLogDeliveryJob; never called synchronously from request paths.
  module Delivery
    module_function

    def deliver_pending(batch_size: 100)
      service.deliver_pending(batch_size:)
    end

    def prune(retention_days: 7)
      service.prune(retention_days:)
    end

    def service(outbox: default_outbox, clock: Time)
      Aiconshell::Observability::DeliveryService.new(
        outbox:, clickhouse: clickhouse_adapter, teams: teams_sink,
        logger: app_logger, clock:
      )
    end

    def clickhouse_adapter
      url = ENV["CLICKHOUSE_URL"].to_s
      return nil if url.empty?

      Aiconshell::Observability::ClickHouseAdapter.new(
        base_url: url,
        database: ENV.fetch("CLICKHOUSE_DATABASE", "aiconshell"),
        table: ENV.fetch("CLICKHOUSE_TABLE", "event_log"),
        username: presence(ENV["CLICKHOUSE_USER"]),
        password: presence(ENV["CLICKHOUSE_PASSWORD"])
      )
    end

    def teams_sink
      Aiconshell::Observability::TeamsSink.new(registry: plugins_registry, logger: app_logger)
    end

    # The plugins port belongs to another lane (docs/architecture.md): resolve
    # it defensively so EventLog keeps working before/after that integration.
    def plugins_registry
      return nil unless defined?(Aiconshell::Plugins::Registry)

      Aiconshell::Plugins::Registry.default
    rescue StandardError
      nil
    end

    def default_outbox
      OutboxAdapter.new
    end

    def app_logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Logger.new(File::NULL)
    end

    def presence(value)
      value.to_s.empty? ? nil : value
    end
  end
end
