# frozen_string_literal: true

# Persisted execution request. Coordination creates rows in `pending`; the
# execution queue leases exactly one job per row via lease_token fencing.
class TaskRun < ApplicationRecord
  STATUSES = %w[pending leased running succeeded failed expired cancelled].freeze
  TERMINAL_STATUSES = %w[succeeded failed expired cancelled].freeze
  ACTIVE_STATUSES = %w[pending leased running].freeze

  belongs_to :task
  attr_readonly :task_id, :provider, :model, :effort, :instructions, :work_snapshot

  validates :provider, presence: true, inclusion: { in: %w[claude codex muse] }
  validates :status, inclusion: { in: STATUSES }
  validates :lease_token, uniqueness: { allow_nil: true }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def lease_expired?(now = Time.current)
    lease_expires_at.present? && lease_expires_at <= now
  end

  def current_for?(task)
    task.status == "running" && task.current_run_id == id
  end

  def live_lease?(task, token, now)
    current_for?(task) && %w[leased running].include?(status) &&
      token.present? && lease_token == token && lease_expires_at.present? && lease_expires_at > now
  end

  # Every workflow path takes the task lock before the run lock. Looking up
  # the immutable task_id first avoids the opposite lock order in workers.
  def self.with_task_lock(run_id)
    task_id = where(id: run_id).pick(:task_id)
    return yield(nil, nil) unless task_id

    transaction do
      task = Task.lock.find_by(id: task_id)
      run = lock.find_by(id: run_id, task_id: task_id)
      yield(run, task)
    end
  end
end
