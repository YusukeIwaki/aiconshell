# frozen_string_literal: true

require "digest"
require "securerandom"

module Aiconshell
  module Oauth
    # High-entropy OAuth state bound to a browser session. Only the SHA256
    # digest is persisted; the raw value travels to the provider and back
    # once, then is discarded. Comparison is constant-time.
    module State
      STATE_BYTES = 32
      DIGEST_BYTES = 32

      module_function

      # Returns { raw:, digest: }. The caller stores digest + session digest
      # and hands raw to the provider authorize URL exactly once.
      def generate
        raw = SecureRandom.urlsafe_base64(STATE_BYTES)
        { raw: raw, digest: digest(raw) }
      end

      def digest(raw)
        Digest::SHA256.hexdigest(raw.to_s)
      end

      def digest_session(session_id)
        Digest::SHA256.hexdigest("oauth-session-v1\0#{session_id}")
      end

      def matches?(expected_digest, raw)
        return false if expected_digest.nil? || raw.nil? || raw.to_s.empty?

        candidate = digest(raw)
        return false unless candidate.bytesize == expected_digest.to_s.bytesize

        # Constant-time comparison without ActiveSupport.
        xor = 0
        candidate.bytes.zip(expected_digest.to_s.bytes) { |a, b| xor |= (a ^ b) }
        xor.zero?
      end
    end
  end
end
