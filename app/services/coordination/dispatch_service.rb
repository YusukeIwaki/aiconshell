# frozen_string_literal: true

module Coordination
  # Creates persisted execution requests. Only Coordination calls this: it
  # moves the task toward running and enqueues exactly one execution job.
  # Callers must hold the task row lock; this service never calls AI.
  class DispatchService
    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    def dispatch(task, now: current_time)
      policy = LayerPolicy.enabled_for("execution")
      provider = policy&.provider || "codex"

      if task.status == "inbox"
        task.transition_to!("ready")
      end
      unless task.transition_allowed?("running") || task.status == "running"
        return nil
      end
      task.transition_to!("running") if task.status == "ready"

      run = TaskRun.create!(
        task: task, provider: provider,
        model: policy&.model, effort: policy&.effort, instructions: policy&.instructions,
        status: "pending", attempt: next_attempt(task)
      )
      task.update!(next_action_at: nil, last_error: nil)
      ExecutionRunJob.perform_later(run.id)
      @event_sink.emit(layer: "coordination", kind: "dispatch.created",
                       message: "Dispatch persisted run #{run.id}",
                       task_id: task.id, data: { run_id: run.id, provider: provider })
      run
    end

    private

    def next_attempt(task)
      (task.task_runs.maximum(:attempt) || 0) + 1
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
