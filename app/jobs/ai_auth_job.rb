# frozen_string_literal: true

# Auth-queue job for one AI connection session. Enqueued by the ops request
# service onto ai_auth_execution; the execution worker pool runs it.
# Legacy ai_auth_control jobs are discarded by
# RequestService#revoke_legacy_control!, never executed. Claim fencing
# makes redelivery safe, so retries never double-run.
class AiAuthJob < ApplicationJob
  queue_as :ai_auth_execution

  retry_on StandardError, wait: :polynomially_longer, attempts: 2

  class << self
    # Test seam: injected fake runtime matching the fixed Runner contract.
    attr_accessor :test_runner
  end

  def perform(session_uuid)
    service = AiAuth::WorkerService.new(runner: self.class.test_runner)
    result = service.call(session_uuid.to_s)
    result.code.to_s
  end
end
