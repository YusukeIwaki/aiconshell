# frozen_string_literal: true

# Coordination-owned outbound intent; Interaction delivers it. The idempotency
# key de-duplicates enqueue retries, not ambiguous external sends (see docs).
class OutboundAction < ApplicationRecord
  OPERATIONS = %w[reply create_issue send_message].freeze
  STATUSES = %w[pending sending sent failed uncertain].freeze
  RETRYABLE_STATUSES = %w[pending].freeze

  belongs_to :task, optional: true

  validates :plugin, :operation, :idempotency_key, presence: true
  validates :operation, inclusion: { in: OPERATIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :idempotency_key, uniqueness: true

  scope :deliverable, ->(now = Time.current) {
    where(status: RETRYABLE_STATUSES).where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
  }
end
