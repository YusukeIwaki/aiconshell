# frozen_string_literal: true

module Coordination
  # Recovers execution leases that expired without a completion. The stale
  # run is parked as expired (its lease token can never complete again via
  # fencing) and a fresh pending run is dispatched while attempts remain;
  # otherwise the task is parked as failed with a visible error.
  class RecoveryService
    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    def call(batch_limit: 50)
      now = current_time
      recovered = 0
      TaskRun.where(status: %w[leased running])
             .where("lease_expires_at IS NOT NULL AND lease_expires_at <= ?", now)
             .order(:lease_expires_at).limit(batch_limit).each do |run|
        recovered += 1 if recover_one(run, now)
      end
      recovered
    end

    private

    def recover_one(run, now)
      TaskRun.transaction do
        run.with_lock do
          next false unless %w[leased running].include?(run.status)
          next false if run.lease_expires_at.nil? || run.lease_expires_at > now
          next false if run.terminal?

          run.task.with_lock do
            task = run.task
            run.update!(status: "expired", finished_at: now,
                        error: "lease expired without completion", error_code: "lease_expired")
            if run.attempt < WorkflowSettings.max_run_attempts
              fresh = TaskRun.create!(
                task: task, provider: run.provider, model: run.model,
                effort: run.effort, instructions: run.instructions,
                status: "pending", attempt: run.attempt + 1
              )
              ExecutionRunJob.perform_later(fresh.id)
              @event_sink.emit(layer: "coordination", kind: "lease.recovered",
                               message: "Run #{run.id} expired; redispatched as #{fresh.id}",
                               task_id: task.id, data: { run_id: run.id, fresh_run_id: fresh.id })
            else
              task.transition_to!("failed") if task.transition_allowed?("failed")
              task.update!(last_error: "execution attempts exhausted after lease expiry",
                           next_action_at: now + 3600)
              @event_sink.emit(layer: "coordination", kind: "lease.exhausted",
                               message: "Run #{run.id} expired; attempts exhausted",
                               task_id: task.id, data: { run_id: run.id })
            end
            true
          end
        end
      end
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
