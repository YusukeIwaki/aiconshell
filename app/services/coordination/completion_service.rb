# frozen_string_literal: true

require "securerandom"

module Coordination
  # Applies structured worker results to tasks. Every completion is fenced by
  # the run lease token: stale or duplicated completions are rejected and
  # never overwrite newer state. Unknown tasks, runs, and transitions fail
  # closed. Runs inside short row-locked transactions; no network/AI here.
  class CompletionService
    Result = Struct.new(:ok, :code, keyword_init: true)

    OUTCOMES = %w[done waiting_review waiting_human failed].freeze

    def initialize(event_sink: WorkflowEvents, clock: Time)
      @event_sink = event_sink
      @clock = clock
    end

    # @param result Hash with "outcome", "summary", optional "reply_body"
    def complete(run_id:, lease_token:, result:)
      now = current_time
      outcome = result.is_a?(Hash) ? (result["outcome"] || result[:outcome]).to_s : ""
      unless OUTCOMES.include?(outcome)
        return Result.new(ok: false, code: :unknown_outcome)
      end

      TaskRun.transaction do
        run = TaskRun.lock.find_by(id: run_id)
        return Result.new(ok: false, code: :unknown_run) if run.nil?
        return Result.new(ok: false, code: :stale_completion) unless run.lease_token == lease_token
        return Result.new(ok: false, code: :stale_completion) if run.terminal?

        run.task.with_lock do
          task = run.task
          unless task.transition_allowed?(outcome) || task.status == outcome
            run.update!(status: "failed", error: "transition #{task.status}->#{outcome} rejected",
                        error_code: "transition_rejected", finished_at: now)
            return Result.new(ok: false, code: :transition_rejected)
          end

          run.update!(status: outcome == "failed" ? "failed" : "succeeded",
                      result: result.is_a?(Hash) ? result : { "summary" => result.to_s },
                      error: nil, error_code: nil, finished_at: now)
          task.transition_to!(outcome) if task.status != outcome
          task.update!(last_error: nil, next_action_at: nil)
          create_reply(task, result) if reply_requested?(result)
          @event_sink.emit(layer: "coordination", kind: "run.completed",
                           message: "Run #{run.id} completed as #{outcome}",
                           task_id: task.id, data: { run_id: run.id, outcome: outcome })
          Result.new(ok: true, code: :ok)
        end
      end
    end

    # Records a structured execution failure (including unconfigured
    # providers) against the run and parks the task as failed/visible.
    def fail_run(run_id:, lease_token:, error_code:, error:)
      now = current_time
      TaskRun.transaction do
        run = TaskRun.lock.find_by(id: run_id)
        return Result.new(ok: false, code: :unknown_run) if run.nil?
        return Result.new(ok: false, code: :stale_completion) unless run.lease_token == lease_token
        return Result.new(ok: false, code: :stale_completion) if run.terminal?

        run.task.with_lock do
          task = run.task
          run.update!(status: "failed", error: error.to_s[0, 2000],
                      error_code: error_code.to_s, finished_at: now)
          if task.transition_allowed?("failed")
            task.transition_to!("failed")
          end
          task.update!(last_error: error.to_s[0, 2000], next_action_at: now + 3600)
          @event_sink.emit(layer: "coordination", kind: "run.failed",
                           message: "Run #{run.id} failed (#{error_code})",
                           task_id: task.id, data: { run_id: run.id, error_code: error_code.to_s })
          Result.new(ok: true, code: :ok)
        end
      end
    end

    private

    def reply_requested?(result)
      body = result["reply_body"] || result[:reply_body]
      body.is_a?(String) && !body.strip.empty?
    end

    def create_reply(task, result)
      body = (result["reply_body"] || result[:reply_body]).to_s
      OutboundAction.create!(
        plugin: task.source_plugin, operation: "reply",
        input: { "resource_id" => task.source_resource_id, "body" => body[0, 4000],
                 "scope" => task.source_resource_id },
        idempotency_key: "completion-#{task.id}-#{SecureRandom.uuid}",
        status: "pending", task: task
      )
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
