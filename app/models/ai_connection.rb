# frozen_string_literal: true

# Worker-confirmed connection snapshot per provider and worker role.
# Single-worker contract (issue 20): current connections are the three
# execution rows (3 providers x execution). Legacy control rows may remain
# but are never displayed as current and never copied to execution.
# The state is only ever written by the auth worker after running the
# official CLI; the web process never infers readiness from local binaries
# or home directories.
class AiConnection < ApplicationRecord
  PROVIDERS = %w[claude codex muse].freeze
  WORKER_ROLES = %w[control execution].freeze
  EXECUTION_ROLE = "execution"
  STATES = %w[unknown connected disconnected unavailable failed].freeze

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :worker_role, presence: true, inclusion: { in: WORKER_ROLES }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :provider, uniqueness: { scope: :worker_role }

  def checked?
    checked_at.present?
  end

  def connected?
    state == "connected"
  end
end
