# frozen_string_literal: true

require "digest"
require "securerandom"

module Aiconshell
  module Oauth
    # PKCE (RFC 7636) for the Microsoft authorization code flow only.
    # Atlassian 3LO is a confidential-client flow with a client secret and
    # has no PKCE parameter in its official spec; this helper must not be
    # wired into the Atlassian provider.
    module Pkce
      VERIFIER_BYTES = 32
      VERIFIER_PATTERN = /\A[A-Za-z0-9\-._~]{43,128}\z/

      module_function

      # Returns { verifier:, challenge: } with a high-entropy verifier and
      # its S256 challenge. Only the challenge leaves the app; the verifier
      # is encrypted into the auth attempt until the code exchange.
      def generate
        verifier = SecureRandom.urlsafe_base64(VERIFIER_BYTES).tr("=", "").tr("+/", "-_")
        verifier = verifier.ljust(43, "0") until VERIFIER_PATTERN.match?(verifier)
        { verifier: verifier, challenge: challenge(verifier) }
      end

      def challenge(verifier)
        text = verifier.to_s
        raise ArgumentError, "invalid PKCE verifier" unless VERIFIER_PATTERN.match?(text)

        require "base64"
        Base64.urlsafe_encode64(Digest::SHA256.digest(text), padding: false)
      end

      def valid_verifier?(value)
        value.is_a?(String) && VERIFIER_PATTERN.match?(value)
      end
    end
  end
end
