# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "json_schemer"

module Aiconshell
  module Observability
    class Error < StandardError; end

    class ValidationError < Error
      attr_reader :details

      def initialize(message, details: [])
        @details = details
        super(message)
      end
    end

    class NotConfiguredError < Error; end
    class SearchError < Error; end
    class ClickHouseError < Error; end
    class SinkError < Error; end

    # Strict event envelope. Built (and redacted) before anything is stored,
    # so the outbox, ClickHouse, and Teams only ever see validated data.
    module Envelope
      LAYERS = %w[interaction coordination execution].freeze
      KIND_PATTERN = /\A[a-z0-9][a-z0-9_.:\-]{0,127}\z/
      UUID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

      VERSION = 1
      MAX_MESSAGE_CHARS = 4000
      MAX_DATA_STRING_CHARS = 2000
      MAX_DATA_BYTES = 32_768
      MAX_ENVELOPE_BYTES = 65_536
      MAX_CORRELATION_ID_CHARS = 128

      SCHEMA = {
        "type" => "object",
        "required" => %w[event_id layer kind message occurred_at data version],
        "additionalProperties" => false,
        "properties" => {
          "event_id" => { "type" => "string", "pattern" => UUID_PATTERN.source },
          "layer" => { "type" => "string", "enum" => LAYERS },
          "kind" => { "type" => "string", "pattern" => KIND_PATTERN.source },
          "message" => { "type" => "string", "minLength" => 1, "maxLength" => MAX_MESSAGE_CHARS },
          "occurred_at" => { "type" => "string", "format" => "date-time" },
          "task_id" => { "type" => %w[integer null] },
          "correlation_id" => { "type" => %w[string null], "maxLength" => MAX_CORRELATION_ID_CHARS },
          "data" => { "type" => "object" },
          "version" => { "type" => "integer", "const" => VERSION }
        }
      }.freeze

      module_function

      def build(layer:, kind:, message:, task_id: nil, correlation_id: nil, data: {},
                event_id: nil, occurred_at: nil, clock: Time)
        raise ValidationError, "data must be a Hash" unless data.is_a?(Hash)
        raise ValidationError, "message must be a String" unless message.is_a?(String)

        safe_data = Redaction.deep_truncate_strings(Redaction.redact(data), MAX_DATA_STRING_CHARS)
        unless json_native?(safe_data)
          raise ValidationError, "data must contain only JSON-native values " \
                                 "(Hash/Array/String/Symbol/numbers/booleans/nil)"
        end
        data_json = JSON.generate(safe_data)
        if data_json.bytesize > MAX_DATA_BYTES
          raise ValidationError, "data exceeds #{MAX_DATA_BYTES} bytes after redaction"
        end

        envelope = {
          "event_id" => event_id || SecureRandom.uuid,
          "layer" => layer,
          "kind" => kind,
          "message" => Redaction.truncate_string(Redaction.redact_string(message), MAX_MESSAGE_CHARS),
          "occurred_at" => normalize_time(occurred_at, clock),
          "task_id" => task_id,
          "correlation_id" => correlation_id,
          "data" => safe_data,
          "version" => VERSION
        }

        envelope_json = begin
          JSON.generate(envelope)
        rescue StandardError
          raise ValidationError, "envelope must be JSON serializable"
        end
        if envelope_json.bytesize > MAX_ENVELOPE_BYTES
          raise ValidationError, "envelope exceeds #{MAX_ENVELOPE_BYTES} bytes"
        end

        validate!(envelope)
      end

      def validate!(envelope)
        raise ValidationError, "envelope must be a Hash" unless envelope.is_a?(Hash)

        schemer = JSONSchemer.schema(SCHEMA)
        errors = schemer.validate(envelope).map do |error|
          "#{error["data_pointer"]}: #{error["type"]} (#{error["schema_pointer"]})"
        end
        unless errors.empty?
          raise ValidationError.new("envelope failed schema validation", details: errors)
        end

        # Explicit time check: JSON Schema `format` handling varies, so never
        # rely on it alone for the occurred_at contract.
        begin
          Time.iso8601(envelope["occurred_at"].to_s)
        rescue ArgumentError
          raise ValidationError, "occurred_at must be ISO8601"
        end

        envelope
      end

      # JSON.generate stringifies arbitrary objects instead of failing, so
      # enforce JSON-native values explicitly for a strict contract.
      def json_native?(value)
        case value
        when Hash
          value.all? { |key, entry| (key.is_a?(String) || key.is_a?(Symbol)) && json_native?(entry) }
        when Array
          value.all? { |entry| json_native?(entry) }
        when String, Symbol, Integer, true, false, nil
          true
        when Float
          value.finite?
        else
          false
        end
      end

      def normalize_time(value, clock)
        time = case value
               when nil then clock.now
               when Time then value
               when String then Time.iso8601(value)
               else raise ValidationError, "occurred_at must be a Time or ISO8601 String"
               end
        time.utc.iso8601(3)
      rescue ArgumentError
        raise ValidationError, "occurred_at must be ISO8601"
      end
    end
  end
end
