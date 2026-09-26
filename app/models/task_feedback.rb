# frozen_string_literal: true

# Separate persisted human input. Never mutates Task directly; Coordination
# triage reads body/suggested_priority and decides state changes.
class TaskFeedback < ApplicationRecord
  belongs_to :task

  validates :body, presence: true
  validates :author_type, inclusion: { in: %w[human] }
  validates :suggested_priority, numericality: { only_integer: true, allow_nil: true }

  scope :unprocessed, -> { where(processed_at: nil) }

  def processed?
    !processed_at.nil?
  end
end
