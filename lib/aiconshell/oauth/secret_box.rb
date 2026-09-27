# frozen_string_literal: true

require "json"

module Aiconshell
  module Oauth
    # Authenticated encryption for OAuth secrets (access/refresh tokens,
    # PKCE verifiers). AES-256-GCM with a key derived from the shared
    # SECRET_KEY_BASE through a dedicated salt, so OAuth ciphertext uses a
    # different key than the AI-auth challenge store. Ciphertext only ever
    # reaches PostgreSQL; plaintext lives in memory for one operation.
    #
    # The key object is injected (32 bytes). Rails callers use
    # Oauth::SecretStore.default; pure-Ruby tests pass an explicit key.
    class SecretBox
      SALT = "aiconshell oauth v1"
      KEY_BYTES = 32

      # Same construction as the framework MessageEncryptor when Rails is
      # present; falls back to OpenSSL directly so unit tests boot Rails-free.
      def self.derive_key(secret_base)
        require "openssl"
        OpenSSL::KDF.pbkdf2_hmac(
          secret_base.to_s, salt: SALT, iterations: 1000,
          length: KEY_BYTES, hash: "SHA256"
        )
      end

      def initialize(key:)
        unless key.is_a?(String) && key.bytesize == KEY_BYTES
          raise ArgumentError, "oauth secret key must be 32 bytes"
        end

        @key = key.dup.freeze
        @crypt = build_crypt
      end

      def encrypt(object)
        payload = JSON.generate(object)
        if @crypt
          @crypt.encrypt_and_sign(payload)
        else
          openssl_encrypt(payload)
        end
      end

      def decrypt(ciphertext)
        raw = ciphertext.to_s
        payload = @crypt ? @crypt.decrypt_and_verify(raw) : openssl_decrypt(raw)
        JSON.parse(payload)
      end

      def inspect
        "#<Aiconshell::Oauth::SecretBox encrypted=true>"
      end

      def to_s
        inspect
      end

      private

      def build_crypt
        require "active_support/message_encryptor"
        crypt = ActiveSupport::MessageEncryptor.new(@key, cipher: "aes-256-gcm", serializer: Passthrough)
        crypt
      rescue LoadError
        nil
      end

      # Passthrough serializer: JSON is encoded explicitly above so the wire
      # format is stable independent of framework defaults.
      class Passthrough
        def self.dump(value)
          value.to_s
        end

        def self.load(value)
          value
        end
      end

      def openssl_encrypt(payload)
        require "openssl"
        require "securerandom"
        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.encrypt
        cipher.key = @key
        iv = SecureRandom.random_bytes(12)
        cipher.iv = iv
        cipher.auth_data = ""
        encrypted = cipher.update(payload) + cipher.final
        tag = cipher.auth_tag(16)
        [iv, tag, encrypted].map { |part| [part].pack("m0") }.join(".")
      end

      def openssl_decrypt(ciphertext)
        require "openssl"
        require "base64"
        parts = ciphertext.to_s.split(".")
        raise ArgumentError, "invalid ciphertext" unless parts.size == 3

        iv = Base64.strict_decode64(parts[0])
        tag = Base64.strict_decode64(parts[1])
        encrypted = Base64.strict_decode64(parts[2])
        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.decrypt
        cipher.key = @key
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = ""
        cipher.update(encrypted) + cipher.final
      rescue ArgumentError, OpenSSL::Cipher::CipherError
        raise ArgumentError, "invalid ciphertext"
      end
    end
  end
end
