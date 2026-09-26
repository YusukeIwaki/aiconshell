# frozen_string_literal: true

module Aiconshell
  module Observability
    # Removes or masks values that must never reach the EventLog or error
    # surfaces: credentials, tokens, auth headers, emails, and AI prompt/raw
    # CLI output carriers.
    #
    # Redaction runs before envelope validation so stored events are already
    # safe. Callers must still avoid passing AI prompts or raw provider
    # output; well-known carrier keys are dropped defensively here.
    module Redaction
      REDACTED = "[REDACTED]"
      REDACTED_EMAIL = "[redacted-email]"
      TRUNCATION_SUFFIX = "…(truncated)"

      # Key segments (split on non-alphanumerics, case-insensitive) that mark
      # a value as sensitive. Single generic words such as "key" or "id" are
      # deliberately absent: "idempotency key" must stay readable.
      SENSITIVE_SEGMENTS = %w[
        auth password passwd secret secrets token tokens
        authorization credential credentials cookie cookies
        session bearer
      ].freeze

      # Substrings that mark a key as sensitive even without word boundaries.
      SENSITIVE_SUBSTRINGS = %w[
        password passwd secret token credential authorization cookie
        apikey api_key access_key private_key client_secret database_url
      ].freeze

      # Payload keys whose values are never logged, even though the key name
      # itself looks innocent (AI prompt and raw CLI output carriers).
      NEVER_LOG_KEYS = %w[
        prompt system_prompt user_prompt
        cli_output raw_cli_output raw_output command_output
        stdout stderr
      ].freeze

      EMAIL_PATTERN = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
      BEARER_PATTERN = %r{\b(?:Bearer|Basic)\s+[A-Za-z0-9\-._~+/=]+}i
      PARAM_PATTERN = /((?:password|passwd|token|secret|api[_-]?key|access[_-]?key|auth(?:orization)?)\s*[=:]\s*)([^&\s;]+)/i

      module_function

      def redact(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), out|
            out[key] = sensitive_key?(key) ? REDACTED : redact(entry)
          end
        when Array
          value.map { |entry| redact(entry) }
        when String
          redact_string(value)
        else
          value
        end
      end

      def redact_string(value)
        redacted = value.gsub(EMAIL_PATTERN, REDACTED_EMAIL)
        redacted = redacted.gsub(BEARER_PATTERN, REDACTED)
        redacted.gsub(PARAM_PATTERN, "\\1#{REDACTED}")
      end

      def sensitive_key?(key)
        normalized = key.to_s.downcase
        return true if NEVER_LOG_KEYS.include?(normalized)

        segments = normalized.split(/[^a-z0-9]+/)
        return true if (segments & SENSITIVE_SEGMENTS).any?

        SENSITIVE_SUBSTRINGS.any? { |part| normalized.include?(part) }
      end

      def truncate_string(value, max_chars)
        return value if value.length <= max_chars
        return value[0, max_chars] if max_chars <= TRUNCATION_SUFFIX.length

        "#{value[0, max_chars - TRUNCATION_SUFFIX.length]}#{TRUNCATION_SUFFIX}"
      end

      def deep_truncate_strings(value, max_chars)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), out|
            out[key] = deep_truncate_strings(entry, max_chars)
          end
        when Array
          value.map { |entry| deep_truncate_strings(entry, max_chars) }
        when String
          truncate_string(value, max_chars)
        else
          value
        end
      end

      # Single-line, redacted, bounded error description safe for logs and
      # outbox `last_error` columns. Never includes backtraces (they may
      # embed environment or arguments).
      def sanitize_error(error, max_chars: 500)
        message = error.respond_to?(:message) ? error.message.to_s : error.to_s
        one_line = message.gsub(/\s+/, " ").strip
        truncate_string(redact_string(one_line), max_chars)
      rescue StandardError
        "#{error.class}"
      end
    end
  end
end
