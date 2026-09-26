# frozen_string_literal: true

module Coordination
  class DispatchService
    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    # Atomic and idempotent even when the caller did not already lock Task.
    # A partial unique index also enforces one active run per task.
    def dispatch(task, now: current_time)
      WorkflowSettings.validate!
      task.with_lock do
        policy = LayerPolicy.enabled_for("execution")
        next nil unless policy

        active = task.task_runs.active.first
        next active if active && active.current_for?(task)
        next nil if active || !%w[inbox ready waiting_human waiting_review failed].include?(task.status)

        task.transition_to!("ready") if %w[inbox failed].include?(task.status)
        run = TaskRun.create!(
          task: task, provider: policy.provider, model: policy.model,
          effort: policy.effort, instructions: policy.instructions,
          status: "pending", attempt: (task.task_runs.maximum(:attempt) || 0) + 1,
          work_snapshot: WorkContext.for_task(task)
        )
        task.transition_to!("running", current_run: run, next_action_at: nil, last_error: nil)
        ExecutionRunJob.perform_later(run.id)
        @event_sink.emit(layer: "coordination", kind: "dispatch.created",
                         message: "Execution request persisted", task_id: task.id,
                         data: { run_id: run.id, provider: run.provider })
        run
      end
    end

    private

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
