# frozen_string_literal: true

# Short-lived auth or status-check request. One active row per
# provider and worker role (partial unique index); double submits return the
# existing active row instead of creating a second one.
#
# Short-term secrets (challenge URL/user code, submitted auth code) are stored
# only as ciphertext in encrypted_challenge/encrypted_input_code and are
# cleared on every terminal transition. Long-lived tokens never touch this
# table; they stay on the worker volume.
class AiAuthSession < ApplicationRecord
  PROVIDERS = %w[claude codex muse].freeze
  WORKER_ROLES = %w[control execution].freeze
  OPERATIONS = %w[login status_check].freeze
  ACTIVE_STATUSES = %w[queued running waiting].freeze
  TERMINAL_STATUSES = %w[succeeded failed cancelled expired].freeze
  STATUSES = (ACTIVE_STATUSES + TERMINAL_STATUSES).freeze

  validates :uuid, presence: true, uniqueness: true
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :worker_role, presence: true, inclusion: { in: WORKER_ROLES }
  validates :operation, presence: true, inclusion: { in: OPERATIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validates :claim_token, uniqueness: { allow_nil: true }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def expired_due?(now = Time.current)
    expires_at.present? && expires_at <= now
  end

  # Decrypted challenge hash or nil. Never raises through callers; a tampered
  # payload reads as absent and the worker fails the session safely.
  def challenge
    raw = encrypted_challenge
    return nil if raw.nil? || raw.empty?

    decoded = AiAuth::SecretBox.default.decrypt(raw)
    decoded.is_a?(Hash) ? decoded : nil
  rescue StandardError
    nil
  end

  def challenge?
    !challenge.nil?
  end

  def input_pending?
    input_code_present?
  end

  def input_code_present?
    !encrypted_input_code.nil? && !encrypted_input_code.empty?
  end

  # True once a code has been accepted, even after the worker consumed and
  # cleared the ciphertext. Used to suppress double submits and to show the
  # "received" state in the UI.
  def input_submitted?
    !input_submitted_at.nil?
  end

  # Atomically fetch and clear the submitted auth code. Returns the String
  # once, then nil on every later call, even across job retries.
  def consume_input_code!
    with_lock do
      raw = encrypted_input_code
      return nil if raw.nil? || raw.empty?

      code = AiAuth::SecretBox.default.decrypt(raw)
      update_columns(encrypted_input_code: nil, input_updated_at: nil, updated_at: Time.current)
      code.is_a?(String) ? code : nil
    end
  rescue StandardError
    with_lock do
      update_columns(encrypted_input_code: nil, input_updated_at: nil, updated_at: Time.current)
    end
    nil
  end

  # Never leak ciphertext (or plaintext) through inspection or error pages.
  def inspect
    "#<AiAuthSession id=#{id.inspect} uuid=#{uuid.inspect} provider=#{provider.inspect} " \
      "worker_role=#{worker_role.inspect} operation=#{operation.inspect} status=#{status.inspect}>"
  end
end
