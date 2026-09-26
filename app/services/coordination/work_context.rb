# frozen_string_literal: true

module Coordination
  # JSON data snapshot persisted with the execution request. A worker never
  # has to reconstruct the human conversation from mutable application rows.
  module WorkContext
    def self.for_task(task)
      {
        "title" => task.title, "description" => task.description,
        "priority" => task.priority, "work_plan" => task.work_plan,
        "source" => { "plugin" => task.source_plugin, "resource_id" => task.source_resource_id },
        "feedback" => task.task_feedbacks.where(author_type: "human").order(:id).map do |feedback|
          { "id" => feedback.id, "author" => feedback.author, "body" => feedback.body }
        end,
        "events" => task.external_events.order(id: :desc).limit(20).reverse.map do |event|
          { "type" => event.event_type, "actor_type" => event.actor_type, "payload" => event.payload }
        end,
        "prior_result" => task.task_runs.where.not(result: nil).order(id: :desc).pick(:result),
        "coordination_result" => coordination_result_for(task),
        "deliveries" => deliveries_for(task)
      }
    end

    # Bounded safe view of the previous admin result plus outbound delivery
    # metadata. When new feedback unlocks a failed/uncertain batch, the AI
    # sees previously attempted writes instead of treating them as unseen
    # work. No action bodies, credentials, or raw errors are included.
    SUMMARY_LIMIT = 500
    DELIVERY_LIMIT = 20

    def self.coordination_result_for(task)
      stored = task.coordination_result
      return nil unless stored.is_a?(Hash)

      {
        "summary" => stored["summary"].to_s[0, SUMMARY_LIMIT],
        "action_count" => stored["action_count"].to_i
      }
    end

    def self.deliveries_for(task)
      task.outbound_actions.order(id: :desc).limit(DELIVERY_LIMIT).reverse.map do |action|
        input = action.input.is_a?(Hash) ? action.input : {}
        {
          "batch_key" => action.delivery_batch_key,
          "plugin" => action.plugin,
          "operation" => action.operation,
          "destination" => Interaction::PluginAccess.destination(
            action.plugin, action.operation, input.transform_keys(&:to_s)),
          "status" => action.status,
          "error_code" => action.error_code
        }
      end
    end
  end
end
