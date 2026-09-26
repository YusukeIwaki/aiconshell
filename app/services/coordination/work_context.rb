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
        "prior_result" => task.task_runs.where.not(result: nil).order(id: :desc).pick(:result)
      }
    end
  end
end
