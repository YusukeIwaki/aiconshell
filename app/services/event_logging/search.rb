# frozen_string_literal: true

require "aiconshell/observability" unless defined?(Aiconshell::Observability)

module EventLogging
  # Rails-facing EventLog search. Reads go to ClickHouse through the
  # configured search backend; all user input is parameterized there.
  module Search
    module_function

    def search(...) = Aiconshell::Observability.search(...)
  end
end
