# frozen_string_literal: true

# Explicit full root (no defined? guard): a pre-defined SecretBox never
# implies the whole entry (State, Pkce, TokenSet, Binding, PROVIDERS) is
# loaded.
require "aiconshell/oauth"

module Oauth
  # Rails key management for the OAuth foundation. The encryption key is
  # derived from the shared SECRET_KEY_BASE through the dedicated
  # "aiconshell oauth v1" salt, so OAuth ciphertext uses a different key
  # than the AI-auth challenge store. Tests inject an explicit 32-byte key.
  class SecretStore
    SALT = Aiconshell::Oauth::SecretBox::SALT

    def self.default
      new(key: default_key)
    end

    def self.default_key
      Rails.application.key_generator.generate_key(SALT, 32)
    end

    def initialize(key:)
      @box = Aiconshell::Oauth::SecretBox.new(key: key)
    end

    def encrypt(object)
      @box.encrypt(object)
    end

    # Returns the plaintext object, or nil when the ciphertext is missing
    # or tampered. Never raises through callers; tampering reads as absent
    # and the operation fails with a safe classification.
    def decrypt(ciphertext)
      return nil if ciphertext.nil? || ciphertext.to_s.empty?

      @box.decrypt(ciphertext)
    rescue StandardError
      nil
    end

    def inspect
      "#<Oauth::SecretStore encrypted=true>"
    end

    def to_s
      inspect
    end
  end
end
