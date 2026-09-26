# frozen_string_literal: true

# Repairs the DB-to-queue gap after process crashes. Duplicate job delivery is
# harmless because both execution and outbound services claim persisted leases.
class WorkflowMaintenanceJob < ApplicationJob
  queue_as :control

  def perform
    Interaction::OutboundService.new.recover_expired!
    Coordination::DeliveryReconciler.new.reconcile_all(limit: 100)
    OutboundAction.deliverable.limit(100).pluck(:id).each { |id| OutboundDeliveryJob.perform_later(id) }
    return unless LayerPolicy.enabled_for("execution")

    TaskRun.where(status: "pending").joins(:task)
      .where(tasks: { status: "running" }).where("tasks.current_run_id = task_runs.id")
      .order("tasks.priority DESC, task_runs.id ASC").limit(100).pluck(:id)
      .each { |id| ExecutionRunJob.perform_later(id) }
  end
end
