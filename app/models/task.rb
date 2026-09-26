# frozen_string_literal: true

# Persistent task owned by Coordination. Only Coordination services may change
# status/priority/next_action_at; controllers persist TaskFeedback instead.
class Task < ApplicationRecord
  STATUSES = %w[inbox ready running waiting_human waiting_review done failed cancelled].freeze

  # Allowed transitions. Unknown transitions are rejected by callers.
  TRANSITIONS = {
    "inbox" => %w[ready cancelled],
    "ready" => %w[running cancelled],
    "running" => %w[waiting_human waiting_review done failed cancelled],
    "waiting_human" => %w[ready running cancelled],
    "waiting_review" => %w[ready running done failed cancelled],
    "failed" => %w[ready cancelled],
    "done" => %w[inbox],
    "cancelled" => %w[inbox]
  }.freeze

  OPEN_STATUSES = %w[inbox ready running waiting_human waiting_review failed].freeze

  has_many :task_feedbacks, class_name: "TaskFeedback", dependent: :destroy
  has_many :task_runs, class_name: "TaskRun", dependent: :destroy
  has_many :outbound_actions, dependent: :nullify
  has_many :external_events, dependent: :nullify
  belongs_to :current_run, class_name: "TaskRun", optional: true

  validates :title, presence: true, length: { maximum: 500 }
  validates :status, inclusion: { in: STATUSES }
  validates :priority, numericality: { only_integer: true }

  scope :open_status, -> { where(status: OPEN_STATUSES) }
  scope :due, ->(now = Time.current) { where("next_action_at IS NULL OR next_action_at <= ?", now) }

  def self.transition_allowed?(from, to)
    TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
  end

  def transition_allowed?(to)
    self.class.transition_allowed?(status, to)
  end

  # Coordination-only helper. Raises ActiveRecord::RecordInvalid on unknown transition.
  def transition_to!(to, **attrs)
    to = to.to_s
    unless transition_allowed?(to)
      errors.add(:status, "transition from #{status} to #{to} is not allowed")
      raise ActiveRecord::RecordInvalid, self
    end
    update!(attrs.merge(status: to))
  end
end
