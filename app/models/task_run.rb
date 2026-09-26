# frozen_string_literal: true

# Persisted execution request. Coordination creates rows in `pending`; the
# execution queue leases exactly one job per row via lease_token fencing.
class TaskRun < ApplicationRecord
  STATUSES = %w[pending leased running succeeded failed expired cancelled].freeze
  TERMINAL_STATUSES = %w[succeeded failed expired cancelled].freeze

  belongs_to :task

  validates :provider, presence: true, inclusion: { in: %w[claude codex muse] }
  validates :status, inclusion: { in: STATUSES }
  validates :lease_token, uniqueness: { allow_nil: true }

  scope :active, -> { where(status: %w[leased running]) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def lease_expired?(now = Time.current)
    lease_expires_at.present? && lease_expires_at <= now
  end
end
