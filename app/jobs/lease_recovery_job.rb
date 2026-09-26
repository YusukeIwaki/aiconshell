# frozen_string_literal: true

# Control-queue recovery of expired execution leases (recurring).
class LeaseRecoveryJob < ApplicationJob
  queue_as :control

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(batch_limit: 50)
    Coordination::RecoveryService.new.call(batch_limit: batch_limit).to_s
  end
end
