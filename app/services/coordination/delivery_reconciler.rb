# frozen_string_literal: true

module Coordination
  # Settles tasks in waiting_delivery (issue #11). Only this reconciler moves
  # tasks out of waiting_delivery: all-sent batches complete as done, while
  # any failed/uncertain delivery parks the task as waiting_human with a
  # content-free reason. No autonomous resend or replanning happens here;
  # new explicit human feedback unlocks later Coordination handling.
  #
  # Membership is exact: the expected batch key and action count come from
  # the persisted task metadata, and a missing/deleted/mismatched action
  # count never vacuously succeeds. Human feedback is never acknowledged.
  class DeliveryReconciler
    Result = Struct.new(:ok, :code, keyword_init: true)

    TERMINAL_DELIVERY = %w[sent failed uncertain].freeze

    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    def reconcile(task_id:)
      Task.transaction do
        task = Task.lock.find_by(id: task_id)
        return Result.new(ok: false, code: :unknown_task) unless task
        return Result.new(ok: false, code: :not_waiting_delivery) unless task.status == "waiting_delivery"

        expected = expected_count(task)
        batch = task.outbound_actions.where(delivery_batch_key: task.delivery_batch_key).order(:id).to_a
        if expected.nil? || task.delivery_batch_key.blank? || batch.size != expected
          return recover_mismatch(task, expected: expected, actual: batch.size)
        end
        return Result.new(ok: false, code: :batch_pending) unless batch.all? { |action| TERMINAL_DELIVERY.include?(action.status) }

        settle_terminal(task, batch)
      end
    end

    # Maintenance sweep. Returns counts only; per-task failures never abort
    # the sweep and never raise.
    def reconcile_all(limit: 100)
      counts = { checked: 0, settled: 0, waiting: 0 }
      Task.where(status: "waiting_delivery").order(:id).limit(limit).pluck(:id).each do |task_id|
        outcome = reconcile(task_id: task_id)
        counts[:checked] += 1
        counts[outcome.ok ? :settled : :waiting] += 1
      rescue StandardError
        counts[:checked] += 1
        counts[:waiting] += 1
      end
      counts
    end

    private

    def expected_count(task)
      count = task.coordination_result.is_a?(Hash) ? task.coordination_result["action_count"] : nil
      count.is_a?(Integer) && count.positive? ? count : nil
    end

    def recover_mismatch(task, expected:, actual:)
      now = current_time
      task.update!(status: "waiting_human", next_action_at: nil,
                   last_error: "Delivery batch incomplete (batch_mismatch)")
      @event_sink.emit(layer: "coordination", kind: "delivery.mismatch", message: "Delivery batch mismatch",
                       task_id: task.id, data: { expected: expected, actual: actual })
      Result.new(ok: true, code: :batch_mismatch)
    end

    # Direct assignment: waiting_delivery has no shared-map edges, so only
    # this reconciler can leave the state. Prior batch metadata and pending
    # human feedback are preserved for operator review and later handling.
    def settle_terminal(task, batch)
      now = current_time
      if batch.all? { |action| action.status == "sent" }
        task.update!(status: "done", next_action_at: nil, last_error: nil)
        @event_sink.emit(layer: "coordination", kind: "delivery.settled", message: "Delivery batch sent",
                         task_id: task.id, data: { action_count: batch.size, outcome: "done" })
        Result.new(ok: true, code: :settled_done)
      else
        failed = batch.any? { |action| action.status == "failed" }
        uncertain = batch.any? { |action| action.status == "uncertain" }
        error_code = (failed && uncertain) ? "delivery_partial" : (failed ? "delivery_failed" : "delivery_uncertain")
        task.update!(status: "waiting_human", next_action_at: nil,
                     last_error: "Delivery requires operator review (#{error_code})")
        @event_sink.emit(layer: "coordination", kind: "delivery.settled", message: "Delivery batch needs review",
                         task_id: task.id,
                         data: { action_count: batch.size, outcome: "waiting_human", error_code: error_code })
        Result.new(ok: true, code: :settled_waiting_human)
      end
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
