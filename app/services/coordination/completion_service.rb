# frozen_string_literal: true

require "json_schemer"

module Coordination
  class CompletionService
    Result = Struct.new(:ok, :code, keyword_init: true)
    OUTCOMES = %w[done waiting_review waiting_human failed].freeze
    RESULT_SCHEMA = {
      "type" => "object", "additionalProperties" => false,
      "properties" => {
        "outcome" => { "type" => "string", "enum" => OUTCOMES },
        "summary" => { "type" => "string", "minLength" => 1, "maxLength" => 8000 },
        "reply_body" => { "type" => "string", "maxLength" => 4000 }
      },
      "required" => %w[outcome summary]
    }.freeze

    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    def complete(run_id:, lease_token:, result:)
      value = result.is_a?(Hash) ? result.deep_stringify_keys : result
      return Result.new(ok: false, code: :invalid_result) unless JSONSchemer.schema(RESULT_SCHEMA).valid?(value)

      TaskRun.with_task_lock(run_id) do |run, task|
        next Result.new(ok: false, code: :unknown_run) unless run && task
        now = current_time
        next Result.new(ok: false, code: :stale_completion) unless run.live_lease?(task, lease_token, now)

        outcome = value.fetch("outcome")
        run.update!(status: outcome == "failed" ? "failed" : "succeeded", result: value,
                    error: nil, error_code: nil, finished_at: now)
        task.transition_to!(outcome, current_run_id: nil, last_error: nil, next_action_at: nil)
        create_reply(task, run, value["reply_body"])
        @event_sink.emit(layer: "coordination", kind: "run.completed", message: "Execution completed",
                         task_id: task.id, data: { run_id: run.id, outcome: outcome })
        Result.new(ok: true, code: :ok)
      end
    end

    def fail_run(run_id:, lease_token:, error_code:, error:)
      TaskRun.with_task_lock(run_id) do |run, task|
        next Result.new(ok: false, code: :unknown_run) unless run && task
        now = current_time
        next Result.new(ok: false, code: :stale_completion) unless run.live_lease?(task, lease_token, now)

        run.update!(status: "failed", error: error.to_s[0, 2000], error_code: error_code.to_s, finished_at: now)
        task.transition_to!("failed", current_run_id: nil, last_error: error.to_s[0, 2000], next_action_at: now + 3600)
        @event_sink.emit(layer: "coordination", kind: "run.failed", message: "Execution failed",
                         task_id: task.id, data: { run_id: run.id, error_code: error_code.to_s })
        Result.new(ok: true, code: :ok)
      end
    end

    private

    def create_reply(task, run, body)
      return if body.to_s.strip.empty? || task.source_plugin.blank? || task.source_resource_id.blank?
      # The internal admin origin is never a reply destination, even for an
      # execution-dispatched admin task. Admin outcomes stay in Task state.
      return if task.source_plugin == Task::ADMIN_PLUGIN

      OutboundAction.create!(
        plugin: task.source_plugin, operation: "reply",
        input: { "resource_id" => task.source_resource_id, "body" => body },
        idempotency_key: "completion-#{run.id}", status: "pending", task: task
      )
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
