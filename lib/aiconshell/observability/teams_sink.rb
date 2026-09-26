# frozen_string_literal: true

require "logger"

module Aiconshell
  module Observability
    # Delivers outbox records to a Teams channel through the plugins port
    # (docs/architecture.md: registry.invoke with plugin/operation/input).
    #
    # The sink is disabled when no registry is injected or the Teams plugin
    # reports itself unconfigured; disabled deliveries are skipped, never
    # retried. Failures are logged through the injected logger only — never
    # re-emitted as events, which would recurse.
    class TeamsSink
      PLUGIN_ID = "teams"
      OPERATION = "send_message"
      MAX_BODY_CHARS = 1000

      def initialize(registry: nil, logger: Logger.new(File::NULL), context: {})
        @registry = registry
        @logger = logger
        @context = { "source" => "event_log" }.merge(stringify_keys(context))
      end

      def enabled?
        return false if @registry.nil?
        return false unless @registry.respond_to?(:invoke)

        teams_configured?
      rescue StandardError => e
        @logger.warn("teams sink catalog check failed: #{Redaction.sanitize_error(e)}")
        false
      end

      # Returns :delivered or :skipped. Raises SinkError when an enabled
      # sink fails (caller applies retry policy).
      def deliver(record)
        channel = record["teams_channel"]
        return :skipped if channel.nil? || channel.to_s.empty?
        return :skipped unless enabled?

        envelope = record["envelope"] || {}
        input = { "scope" => channel.to_s, "body" => self.class.format_message(envelope) }
        validate_input!(input)
        @registry.invoke(plugin: PLUGIN_ID, operation: OPERATION, input:, context: @context)
        :delivered
      rescue SinkError
        raise
      rescue StandardError => e
        raise SinkError, "teams delivery failed: #{Redaction.sanitize_error(e)}"
      end

      def self.format_message(envelope)
        layer = envelope["layer"]
        kind = envelope["kind"]
        message = envelope["message"].to_s
        task = envelope["task_id"] ? " (task ##{envelope["task_id"]})" : ""
        Redaction.truncate_string("[#{layer}/#{kind}] #{message}#{task}", MAX_BODY_CHARS)
      end

      private

      def teams_configured?
        return true unless @registry.respond_to?(:catalog)

        Array(@registry.catalog).any? do |entry|
          next false unless entry.is_a?(Hash)

          id = entry["id"] || entry[:id]
          next false unless id.to_s == PLUGIN_ID

          configured = entry.key?("configured") ? entry["configured"] : entry[:configured]
          !!configured
        end
      end

      def validate_input!(input)
        raise SinkError, "teams scope must be present" if input["scope"].empty?
        raise SinkError, "teams body must be present" if input["body"].empty?
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end
    end
  end
end
