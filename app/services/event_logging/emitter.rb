# frozen_string_literal: true

require "aiconshell/observability" unless defined?(Aiconshell::Observability)

module EventLogging
  # Rails-facing emit entry point. Safe inside transactions: it only writes
  # a redacted envelope to the outbox spool and never performs network I/O.
  # Use .emit (never raises) in business code; .emit! (raises
  # ValidationError) in tests and boot checks.
  module Emitter
    module_function

    def emit(...) = Aiconshell::Observability.emit(...)

    def emit!(...) = Aiconshell::Observability.emit!(...)
  end
end
