# frozen_string_literal: true

require "json"
require "active_support/message_encryptor"

module AiAuth
  # Short-term secret store for auth challenges and submitted codes.
  # AES-256-GCM via MessageEncryptor, JSON serialization, key derived from the
  # shared SECRET_KEY_BASE through the Rails key generator. Ciphertext only
  # ever reaches PostgreSQL; plaintext lives in memory for one operation.
  class SecretBox
    # Passthrough serializer: we JSON-encode explicitly so the wire format is
    # always JSON, independent of framework defaults.
    class JsonString
      def self.dump(value)
        value.to_s
      end

      def self.load(value)
        value
      end
    end

    def self.default
      new(key: default_key)
    end

    def self.default_key
      Rails.application.key_generator.generate_key("aiconshell ai auth v1", 32)
    end

    def initialize(key:)
      unless key.is_a?(String) && key.bytesize == 32
        raise ArgumentError, "auth secret key must be 32 bytes"
      end

      @crypt = ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JsonString)
    end

    def encrypt(object)
      @crypt.encrypt_and_sign(JSON.generate(object))
    end

    def decrypt(ciphertext)
      JSON.parse(@crypt.decrypt_and_verify(ciphertext.to_s))
    end
  end
end
