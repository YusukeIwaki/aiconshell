# frozen_string_literal: true

# Execution-queue worker for one persisted TaskRun. Never runs inline in web
# requests; controllers cannot enqueue or invoke this job directly — only
# Coordination dispatch persists the run and enqueues it.
class ExecutionRunJob < ApplicationJob
  queue_as :execution

  # Lease fencing makes re-execution safe, but AI calls are not retried
  # blindly: structured failures are persisted by the runner instead.
  retry_on StandardError, wait: :polynomially_longer, attempts: 2

  def perform(task_run_id)
    Execution::RunnerService.new.call(task_run_id).code.to_s
  end
end
