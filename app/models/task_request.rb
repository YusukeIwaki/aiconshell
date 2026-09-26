# frozen_string_literal: true

# Durable receipt for one accepted admin task request. The intake service is
# the only writer; controllers look rows up by the opaque request_id and never
# by integer id or by ExternalEvent identity.
class TaskRequest < ApplicationRecord
  belongs_to :external_event

  NAMESPACES = %w[ui api].freeze
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  API_KEY_RE = /\A[A-Za-z0-9_\-:.]{1,128}\z/

  validates :request_id, presence: true, uniqueness: true, format: { with: UUID_RE }
  validates :idempotency_namespace, inclusion: { in: NAMESPACES }
  validates :idempotency_key, presence: true
  validate :idempotency_key_format
  validates :title, presence: true, length: { maximum: 500 }
  validates :description, presence: true, length: { maximum: 8000 }
  validates :external_event_id, uniqueness: true

  before_validation :strip_text

  def to_param
    request_id
  end

  def processed?
    external_event&.processed? || false
  end

  def status
    processed? ? "processed" : "accepted"
  end

  def task_id
    external_event&.task_id
  end

  private

  def strip_text
    self.title = title.to_s.strip
    self.description = description.to_s.strip
  end

  def idempotency_key_format
    key = idempotency_key.to_s
    valid = if idempotency_namespace == "ui"
      key.match?(UUID_RE)
    else
      key.match?(API_KEY_RE)
    end
    errors.add(:idempotency_key, "is invalid") unless valid
  end
end
