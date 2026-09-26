# frozen_string_literal: true

module Aiconshell
  module Ai
    # Base class for all Ai port errors. Messages are pre-redacted and carry
    # only bounded excerpts; they never include auth file contents or raw
    # provider stdout.
    class Error < StandardError
    end

    # Raised when the provider id is not one of the fixed catalog entries.
    class UnknownProvider < Error
      attr_reader :provider

      def initialize(provider)
        @provider = provider
        super("unknown AI provider: #{provider.inspect} (expected claude, codex or muse)")
      end
    end

    # Raised at execution time when the provider CLI or its private auth
    # location is missing. Subscription validity itself is a runtime concern
    # and surfaces as ExecutionFailed instead.
    class NotConfigured < Error
      attr_reader :provider, :diagnosis

      def initialize(provider, diagnosis = {})
        @provider = provider
        @diagnosis = diagnosis
        super(build_message)
      end

      private

      def build_message
        detail = diagnosis.is_a?(Hash) ? diagnosis : {}
        parts = []
        parts << "executable #{detail[:executable].inspect} not found" unless detail[:executable_found]
        parts << "auth location #{detail[:home].inspect} missing" unless detail[:home_present]
        parts = ["not configured"] if parts.empty?
        "AI provider #{provider.inspect} is #{parts.join("; ")}"
      end
    end

    # Raised when the provider CLI exceeds its timeout. The child process
    # group has been terminated (TERM then KILL) before this error is raised.
    class TimeoutError < Error
      attr_reader :provider, :timeout

      def initialize(provider, timeout)
        @provider = provider
        @timeout = timeout
        super("AI provider #{provider.inspect} timed out after #{timeout}s")
      end
    end

    # Short alias matching the issue vocabulary (Ai::Timeout).
    Timeout = TimeoutError

    # Raised when the provider CLI exits non-zero or reports a terminal
    # failure. #kind classifies the failure heuristically from stderr:
    # :auth, :usage_limit, :not_found or :generic.
    class ExecutionFailed < Error
      attr_reader :provider, :exit_status, :kind, :excerpt

      def initialize(provider, exit_status:, kind: :generic, excerpt: nil)
        @provider = provider
        @exit_status = exit_status
        @kind = kind
        @excerpt = excerpt
        super(build_message)
      end

      private

      def build_message
        message = "AI provider #{provider.inspect} failed (exit=#{exit_status.inspect}, kind=#{kind})"
        message += ": #{excerpt}" if excerpt && !excerpt.empty?
        message
      end
    end

    # Raised when provider output is truncated, is not valid JSON, or does
    # not satisfy the caller-supplied JSON Schema.
    class InvalidOutput < Error
      attr_reader :provider

      def initialize(provider, detail)
        @provider = provider
        super("AI provider #{provider.inspect} returned invalid output: #{detail}")
      end
    end
  end
end
