# frozen_string_literal: true

module Coordination
  class RecoveryService
    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    def call(batch_limit: 50)
      now = current_time
      ids = TaskRun.where(status: %w[leased running]).where("lease_expires_at <= ?", now)
                   .order(:lease_expires_at).limit(batch_limit).pluck(:id)
      ids.count { |id| recover_one(id, now) }
    end

    private

    def recover_one(id, now)
      TaskRun.with_task_lock(id) do |run, task|
        now = current_time
        next false unless run && task && %w[leased running].include?(run.status) && run.lease_expired?(now)

        unless run.current_for?(task)
          run.update!(status: "cancelled", finished_at: now, error_code: "superseded", error: "Run is no longer current")
          next true
        end

        run.update!(status: "expired", finished_at: now, error_code: "lease_expired", error: "Lease expired without completion")
        if run.attempt < WorkflowSettings.max_run_attempts && LayerPolicy.enabled_for("execution")
          fresh = TaskRun.create!(
            task: task, provider: run.provider, model: run.model, effort: run.effort,
            instructions: run.instructions, work_snapshot: run.work_snapshot,
            status: "pending", attempt: run.attempt + 1
          )
          task.update!(current_run: fresh)
          ExecutionRunJob.perform_later(fresh.id)
          @event_sink.emit(layer: "coordination", kind: "lease.recovered", message: "Expired execution redispatched",
                           task_id: task.id, data: { run_id: run.id, fresh_run_id: fresh.id })
        else
          reason = LayerPolicy.enabled_for("execution") ? "execution attempts exhausted after lease expiry" : "execution policy disabled"
          task.transition_to!("failed", current_run_id: nil, last_error: reason, next_action_at: now + 3600)
          @event_sink.emit(layer: "coordination", kind: "lease.exhausted", message: "Execution recovery stopped",
                           task_id: task.id, data: { run_id: run.id })
        end
        true
      end
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
