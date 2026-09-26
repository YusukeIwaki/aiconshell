# frozen_string_literal: true

module Aiconshell
  module Ai
    # Failure classification for provider output. Raw stdout/stderr is
    # matched here to pick a kind, then discarded: no excerpt helper is
    # offered on purpose, so unknown secrets and echoed prompts cannot
    # leak into errors, the EventLog, the database or admin pages.
    # Pattern-based redaction was deliberately removed — an allowlist of
    # secret shapes can never cover unknown tokens.
    module Redactor
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
