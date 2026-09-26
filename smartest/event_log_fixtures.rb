# frozen_string_literal: true

# Network-free EventLog fixtures (fixed clock, memory outbox, log capture).
# Safe for smartest/unit; integration tests get these plus Rails/ClickHouse
# fixtures from integration/observability_helper.
require "event_log_support"

class EventLogFixtures < Smartest::Fixture
  fixture :fixed_clock do
    EventLogTestSupport::FixedClock.new
  end

  fixture :memory_outbox do |fixed_clock:|
    Aiconshell::Observability::MemoryOutbox.new(clock: fixed_clock)
  end

  fixture :log_output do
    StringIO.new
  end

  fixture :test_logger do |log_output:|
    Logger.new(log_output)
  end
end

around_suite do |suite|
  use_fixture EventLogFixtures
  around_test do |test|
    Aiconshell::Observability.reset!
    test.run
    Aiconshell::Observability.reset!
  end
  suite.run
end
