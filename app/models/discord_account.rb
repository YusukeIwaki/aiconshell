# frozen_string_literal: true

# Singleton Discord Bot account (issue #28). The token lives here, not in
# the environment, stored only as authenticated ciphertext; plaintext
# lives in memory for one operation and is never rendered back.
class DiscordAccount < ApplicationRecord
  # Transient admin-form flag; never persisted.
  attr_accessor :clear_token

  has_one :health_check_state, class_name: "DiscordHealthCheckState", dependent: :destroy

  scope :ordered, -> { order(:id) }

  def self.current
    ordered.first_or_create!
  end

  def configured?
    bot_token.present?
  end

  def bot_token?
    encrypted_bot_token.present?
  end

  # Decrypted token, or nil when unset or tampered. Never raises through
  # callers; tampering reads as absent and the operation fails with a
  # safe classification.
  def bot_token
    raw = encrypted_bot_token
    return nil if raw.nil? || raw.empty?

    decoded = Accounts::SecretBox.default.decrypt(raw)
    decoded.is_a?(String) && decoded.present? ? decoded : nil
  rescue StandardError
    nil
  end

  # Stores token text as ciphertext. Blank input clears the stored token.
  def bot_token=(text)
    value = text.to_s.strip
    self.encrypted_bot_token = value.empty? ? nil : Accounts::SecretBox.default.encrypt(value)
  end

  def credential_env
    { "DISCORD_BOT_TOKEN" => bot_token.to_s }
  end

  # Ciphertext (or plaintext) never leaks through inspection or error pages.
  def inspect
    "#<DiscordAccount id=#{id.inspect} token=#{bot_token? ? 'set' : 'unset'}>"
  end

  def serializable_hash(options = nil)
    super(options).except("encrypted_bot_token")
  end
end
