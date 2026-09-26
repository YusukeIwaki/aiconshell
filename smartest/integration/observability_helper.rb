# frozen_string_literal: true

# EventLog Rails integration tests: real PostgreSQL (via db_helper's *_test
# guard and per-test transaction rollback) plus ClickHouse on demand.
# Requires RAILS_ENV=test with TEST_DATABASE_URL pointing at a *_test DB.
require "db_helper"
require "event_log_support"

# Observability config is global: snapshot the boot wiring and restore it
# after each test so unit-style configure blocks cannot leak.
class EventLogRailsFixture < Smartest::Fixture
  fixture :observability_config do
    config = Aiconshell::Observability.config
    snapshot = { outbox: config.outbox, search_backend: config.search_backend,
                 logger: config.logger, clock: config.clock }
    on_teardown do
      Aiconshell::Observability.configure do |restored|
        restored.outbox = snapshot[:outbox]
        restored.search_backend = snapshot[:search_backend]
        restored.logger = snapshot[:logger]
        restored.clock = snapshot[:clock]
      end
    end
    snapshot
  end

  fixture :real_clickhouse do
    begin
      EventLogTestSupport::ClickHouseConfig.ensure_test_database!
    rescue IOError, SocketError, SystemCallError, Timeout::Error => e
      raise Smartest::Skipped, "clickhouse unreachable: #{e.message}"
    end
    EventLogTestSupport::ClickHouseConfig.adapter
  end

  fixture :ch_event_log do |real_clickhouse:|
    EventLogTestSupport::ClickHouseConfig.rebuild_event_log_from_shipped_sql!
    on_teardown do
      EventLogTestSupport::ClickHouseConfig.execute!("DROP TABLE IF EXISTS event_log")
    rescue StandardError
      nil
    end
    real_clickhouse
  end
end

around_suite do |suite|
  use_fixture EventLogRailsFixture
  suite.run
end
