# frozen_string_literal: true

require "uri"

module Aiconshell
  module Ai
    module Authentication
      # Strict allowlist for the verification URLs a login flow may present.
      # Each provider has exactly one official HTTPS host and path (measured
      # against the pinned CLIs; see docs/ai-auth-protocol.md). Anything else
      # — http, userinfo, suspicious ports, control characters, fragments,
      # unlisted hosts or paths — is rejected so a spoofed prompt can never
      # reach the admin UI as a challenge. The query string is preserved
      # byte-for-byte because the flow needs it.
      module UrlPolicy
        RULES = {
          "claude" => { host: "claude.com", path: "/cai/oauth/authorize" },
          "codex" => { host: "auth.openai.com", path: "/codex/device" },
          "muse" => { host: "auth.meta.com", path: "/oauth/device/" }
        }.freeze

        MAX_URL_CHARS = 2048

        module_function

        # @return [String, nil] the original URL when it satisfies the
        #   provider rule, nil otherwise.
        def validate(provider, raw)
          rule = RULES[provider]
          return nil if rule.nil?
          return nil unless raw.is_a?(String)
          return nil if raw.empty? || raw.length > MAX_URL_CHARS
          return nil unless raw.ascii_only?
          return nil if raw.match?(/[\x00-\x20\x7F]/) || raw.include?("\\")

          uri = URI.parse(raw)
          return nil unless uri.is_a?(URI::HTTPS)
          return nil unless uri.userinfo.nil?
          return nil unless uri.host&.downcase == rule[:host]
          return nil unless uri.port == 443
          return nil unless uri.path == rule[:path]
          return nil unless uri.fragment.nil?

          raw
        rescue URI::InvalidURIError
          nil
        end
      end
    end
  end
end
