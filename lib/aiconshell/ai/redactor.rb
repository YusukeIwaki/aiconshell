# frozen_string_literal: true

module Aiconshell
  module Ai
    # Redaction helpers for provider output. Error messages and excerpts pass
    # through here so secrets, tokens and raw stdout never reach the EventLog,
    # the database or admin error pages.
    module Redactor
      BEARER_PATTERN = /(?i)\bbearer\s+[A-Za-z0-9\-._~+\/=]+/
      ASSIGNMENT_PATTERN = /(?i)(api[_-]?key|auth[_-]?token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|password|passwd|pwd|authorization)\s*[:=]\s*\S+/
      TOKEN_PREFIX_PATTERN = /\b(sk-[A-Za-z0-9_\-]{8,}|xox[baprs]-[A-Za-z0-9\-]{8,}|gh[op]_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_\-]{8,})\b/

      AUTH_PATTERNS = [
        /not\s+logged\s+in/i,
        /login\s+required/i,
        /unauthori[sz]ed/i,
        /\b401\b/,
        /\b403\b.*token/i,
        /invalid\s+(api\s+)?key/i,
        /token\s+(expired|invalid|revoked)/i,
        /authentication\s+(failed|error|required)/i,
        /auth\s+(failed|error|required)/i,
        /oauth/i,
        /subscription/i,
        /please\s+(run\s+)?.*login/i
      ].freeze

      USAGE_LIMIT_PATTERNS = [
        /usage[\s_-]?limit/i,
        /rate[\s_-]?limit/i,
        /too\s+many\s+requests/i,
        /\b429\b/,
        /quota/i,
        /overloaded/i,
        /capacity/i,
        /try\s+again\s+later/i,
        /limit\s+reached/i,
        /usage\s+exceeded/i
      ].freeze

      NOT_FOUND_PATTERNS = [
        /command\s+not\s+found/i,
        /no\s+such\s+file/i,
        /ENOENT/i,
        /not\s+installed/i,
        /executable\s+not\s+found/i
      ].freeze

      module_function

      # Replace secret-looking fragments with [REDACTED]. Conservative: plain
      # prose passes through unchanged.
      def redact(text)
        redacted = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
        redacted = redacted.gsub(BEARER_PATTERN, "bearer [REDACTED]")
        redacted = redacted.gsub(ASSIGNMENT_PATTERN) { "#{::Regexp.last_match(1)}=[REDACTED]" }
        redacted.gsub(TOKEN_PREFIX_PATTERN, "[REDACTED]")
      end

      # Bounded, single-line excerpt for error messages.
      def excerpt(text, max_chars: 500)
        clean = redact(text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?"))
        clean = clean.strip.gsub(/\s+/, " ")
        return clean if clean.length <= max_chars

        "#{clean[0, max_chars]}...(truncated)"
      end

      # Heuristic failure classification from stderr text.
      def failure_kind(stderr)
        text = stderr.to_s
        return :auth if AUTH_PATTERNS.any? { |pattern| pattern.match?(text) }
        return :usage_limit if USAGE_LIMIT_PATTERNS.any? { |pattern| pattern.match?(text) }
        return :not_found if NOT_FOUND_PATTERNS.any? { |pattern| pattern.match?(text) }

        :generic
      end
    end
  end
end
