# frozen_string_literal: true

require "securerandom"

# Bearer [REDACTED] the JSON admin API (issue #28). Only a SHA256 digest is
# stored; the plaintext is generated here and shown to the operator once
# at rotation time. No row (or a blank digest) fails every request closed.
class AdminApiToken < ApplicationRecord
  PREFIX_CHARS = 6

  scope :ordered, -> { order(:id) }

  validates :token_digest, presence: true, uniqueness: true

  def self.current
    ordered.first
  end

  def self.digest_for(plaintext)
    Digest::SHA256.hexdigest(plaintext.to_s)
  end

  # Creates or replaces the singleton token. Returns [record, plaintext];
  # the plaintext is never persisted and must be shown once.
  def self.rotate!
    plaintext = SecureRandom.hex(32)
    record = ordered.first_or_initialize
    record.token_digest = digest_for(plaintext)
    record.prefix = plaintext[0, PREFIX_CHARS]
    record.save!
    [record, plaintext]
  end

  def matches?(plaintext)
    given = plaintext.to_s
    return false if given.empty? || token_digest.to_s.empty?

    ActiveSupport::SecurityUtils.secure_compare(
      self.class.digest_for(given), token_digest.to_s
    )
  end

  def inspect
    "#<AdminApiToken id=#{id.inspect} prefix=#{prefix.inspect}>"
  end

  def serializable_hash(options = nil)
    super(options).except("token_digest")
  end
end
