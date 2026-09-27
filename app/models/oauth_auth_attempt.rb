# frozen_string_literal: true

# Explicit full root (no defined? guard): a pre-defined ErrorCodes never
# implies the whole entry (State, Pkce, TokenSet, Binding, PROVIDERS) is
# loaded.
require "aiconshell/oauth"

# One short-lived OAuth authorization attempt. Only the SHA256 digest of the
# high-entropy state (bound to the browser session digest) is stored; the
# raw state travels to the provider and back once. The PKCE verifier
# (Microsoft only) is stored as ciphertext until the code exchange, and the
# authorization code itself is never persisted. Rows are one-time: the first
# callback consumes the row and every later use is rejected.
class OauthAuthAttempt < ApplicationRecord
  PROVIDERS = %w[atlassian microsoft].freeze
  STATUSES = %w[pending consumed succeeded failed expired].freeze
  ACTIVE_STATUSES = %w[pending consumed].freeze

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :state_digest, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    !active?
  end

  def expired_due?(now = Time.current)
    expires_at.present? && expires_at <= now
  end

  # Atomically consume a pending row. Returns true exactly once; every
  # later call (double callback, retry, replay) returns false.
  def consume_once!
    with_lock do
      return false unless status == "pending"

      update!(status: "consumed", consumed_at: Time.current)
      true
    end
  end

  # Raw state, verifier, and ciphertext never leak through inspection.
  def inspect
    "#<OauthAuthAttempt id=#{id.inspect} provider=#{provider.inspect} status=#{status.inspect}>"
  end

  def serializable_hash(options = nil)
    super(options).except("state_digest", "browser_session_digest", "encrypted_code_verifier")
  end
end
