# frozen_string_literal: true

require "json_schemer"

module Aiconshell
  module Ai
    # Validates provider output against the caller-supplied JSON Schema.
    # json_schemer resolves local pointers only by default: remote $refs
    # raise instead of hitting the network, so validation stays offline.
    module SchemaValidator
      module_function

      def validate!(data, schema, provider:)
        unless schema.is_a?(Hash)
          raise ArgumentError, "schema must be a Hash, got #{schema.class}"
        end

        schemer = compile(schema)
        valid = check_valid(schemer, data)
        return data if valid

        raise InvalidOutput.new(provider, describe_errors(schemer.validate(data)))
      end

      def compile(schema)
        JSONSchemer.schema(schema)
      rescue StandardError => error
        # Developer-facing (raised before any provider I/O): the schema is
        # app-authored, so a bounded slice of the library message is safe.
        raise ArgumentError, "invalid JSON schema (#{error.class}): #{bound(error.message)}"
      end

      def check_valid(schemer, data)
        schemer.valid?(data)
      rescue JSONSchemer::UnknownRef
        raise ArgumentError, "remote $ref is not supported"
      end

      # Single-line, bounded slice for developer-facing messages only.
      # Never used for provider output.
      def bound(message, max_chars: 200)
        clean = message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
        clean = clean.strip.gsub(/\s+/, " ")
        return clean if clean.length <= max_chars

        "#{clean[0, max_chars]}...(truncated)"
      end

      # Error detail lists JSON pointers and expected types only. Values from
      # provider output are never echoed back, keeping TaskRun#error safe.
      def describe_errors(errors)
        details = errors.first(5).map do |error|
          pointer = error["data_pointer"].to_s.empty? ? "/" : error["data_pointer"]
          expected = error["type"] || error["schema_pointer"]
          "#{pointer} (expected #{expected})"
        end
        "schema validation failed: #{details.join("; ")}"
      end
    end
  end
end
