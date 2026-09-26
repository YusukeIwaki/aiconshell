# frozen_string_literal: true

# EventLog (issue #5) Rails wiring: point the Aiconshell::Observability port
# at the ActiveRecord outbox and the ENV-configured ClickHouse search backend.
#
# Reload-safe: to_prepare re-runs on every reload in development, so the port
# never holds a stale adapter class. Boot performs no DB or network I/O:
# OutboxAdapter.new is a plain object, and clickhouse_adapter only reads ENV
# (nil when CLICKHOUSE_URL is missing, in which case search raises
# NotConfiguredError instead of silently using the MemoryOutbox default).
require "aiconshell/observability"

Rails.application.config.to_prepare do
  Aiconshell::Observability.configure do |config|
    config.outbox = EventLogging::OutboxAdapter.new
    config.search_backend = EventLogging::Delivery.clickhouse_adapter
    config.default_teams_channel = ENV["EVENT_LOG_TEAMS_CHANNEL"].presence
    config.logger = Rails.logger if Rails.logger
  end
end
