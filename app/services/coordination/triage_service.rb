# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Coordination
  # Owns every Task lifecycle decision. Two phases:
  #
  # 1. Deterministic ingest: unprocessed human events become a new inbox Task
  #    or TaskFeedback on the already-open Task for the same source. Bot
  #    events never reach this service (stored pre-processed by polling).
  # 2. AI triage: the coordination policy model ranks due tasks and requests
  #    priority/status/dispatch/outbound decisions through a strict schema.
  #    Unknown tasks, actions, and transitions are rejected per ruling.
  #
  # Without an enabled coordination policy only phase 1 runs; tasks stay in
  # inbox awaiting configuration. The deterministic priority fallback runs in
  # explicit demo mode only. AI subprocesses run outside DB transactions.
  class TriageService
    Result = Struct.new(:ok, :code, :ingested, :triaged, :rejected, keyword_init: true)

    DECISION_SCHEMA = {
      "type" => "object",
      "properties" => {
        "rulings" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "task_id" => { "type" => "integer" },
              "priority" => { "type" => "integer" },
              "status" => { "type" => "string" },
              "dispatch" => { "type" => "boolean" },
              "reply" => {
                "type" => "object",
                "properties" => {
                  "plugin" => { "type" => "string" },
                  "operation" => { "type" => "string" },
                  "resource_id" => { "type" => "string" },
                  "body" => { "type" => "string" }
                },
                "required" => %w[plugin operation body]
              }
            },
            "required" => ["task_id"]
          }
        }
      },
      "required" => ["rulings"]
    }.freeze

    def initialize(ai_runner: nil, event_sink: WorkflowEvents, clock: Time)
      @ai_runner = ai_runner || default_runner
      @event_sink = event_sink
      @clock = clock
    end

    def call(batch_limit: 50)
      now = current_time
      ingested = ingest_events(batch_limit, now)
      triaged, rejected = triage_due_tasks(batch_limit, now)
      Result.new(ok: true, code: :ok, ingested: ingested, triaged: triaged, rejected: rejected)
    end

    private

    def default_runner
      return nil unless defined?(Aiconshell::Ai::Runner)

      Aiconshell::Ai::Runner.new
    rescue StandardError
      nil
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end

    # Phase 1: map each human event to the open task for its source, or mint
    # one inbox task. Holds row locks only inside the ingest transaction.
    def ingest_events(batch_limit, now)
      count = 0
      ExternalEvent.unprocessed.human.order(:occurred_at).limit(batch_limit).each do |event|
        ExternalEvent.transaction do
          event.with_lock do
            next if event.processed?

            Task.transaction do
              task = find_open_task(event)
              if task.nil?
                Task.create!(
                  title: title_from(event), description: body_from(event),
                  status: "inbox", priority: 0,
                  source_plugin: event.plugin, source_resource_id: event.resource_id
                )
              else
                task.with_lock do
                  TaskFeedback.create!(
                    task: task, body: body_from(event),
                    author: event.actor_id.to_s, author_type: "human"
                  )
                end
              end
              event.update!(processed_at: now, last_error: nil)
              count += 1
            end
          end
        end
      end
      @event_sink.emit(layer: "coordination", kind: "triage.ingested",
                       message: "Ingested #{count} event(s)", data: { ingested: count }) if count.positive?
      count
    end

    def find_open_task(event)
      Task.where(source_plugin: event.plugin, source_resource_id: event.resource_id)
          .open_status.order(updated_at: :desc).first
    end

    # Phase 2: rank due tasks via the coordination policy.
    def triage_due_tasks(batch_limit, now)
      tasks = Task.open_status.due(now).order(priority: :desc, updated_at: :asc).limit(batch_limit).to_a
      return [0, 0] if tasks.empty?

      policy = LayerPolicy.enabled_for("coordination")
      if policy.nil?
        if WorkflowSettings.demo_mode?
          return apply_demo_fallback(tasks, now)
        end
        return [0, 0]
      end

      if @ai_runner.nil?
        backoff_tasks(tasks, now, "coordination AI runner is not available")
        return [0, 0]
      end

      answer = invoke_ai(policy, tasks, now)
      unless answer[:ok]
        backoff_tasks(tasks, now, answer[:error])
        @event_sink.emit(layer: "coordination", kind: "triage.ai_failed",
                         message: "Coordination AI failed", data: { error_code: answer[:code].to_s })
        return [0, 0]
      end

      apply_rulings(tasks, Array(answer[:rulings]), now)
    end

    def invoke_ai(policy, tasks, now)
      prompt = build_prompt(tasks)
      workspace = ensure_workspace("coordination")
      answer = @ai_runner.call(
        provider: policy.provider, prompt: prompt, schema: DECISION_SCHEMA,
        workspace: workspace, layer: "coordination",
        model: policy.model, effort: policy.effort, instructions: policy.instructions,
        timeout: WorkflowSettings.ai_timeout_seconds
      )
      rulings = answer["rulings"] || answer[:rulings] || []
      { ok: true, rulings: Array(rulings) }
    rescue StandardError => e
      { ok: false, code: error_code(e), error: "coordination AI failed (#{error_code(e)}): #{safe_message(e)}" }
    end

    def error_code(error)
      name = error.class.name.to_s
      return :provider_not_configured if name.match?(/NotConfigured|NotFound|Unknown/i)
      return :provider_timeout if name.match?(/Timeout/i)
      return :provider_invalid_output if name.match?(/InvalidOutput|Schema|Validation/i)

      :provider_error
    end

    def apply_rulings(tasks, rulings, now)
      by_id = tasks.index_by(&:id)
      triaged = 0
      rejected = 0
      rulings.each do |raw|
        ruling = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
        task = by_id[ruling["task_id"].to_i]
        if task.nil?
          rejected += 1
          next
        end
        ok = apply_ruling(task, ruling, now)
        ok ? triaged += 1 : rejected += 1
      end
      # Feedback for triaged tasks is consumed; rejected rulings leave feedback
      # unprocessed so the next triage can reconsider it.
      mark_feedback_processed(tasks, now) if triaged.positive?
      @event_sink.emit(layer: "coordination", kind: "triage.completed",
                       message: "Triaged #{triaged}, rejected #{rejected}",
                       data: { triaged: triaged, rejected: rejected }) if (triaged + rejected).positive?
      [triaged, rejected]
    end

    def apply_ruling(task, ruling, now)
      Task.transaction do
        task.with_lock do
          if ruling.key?("priority")
            priority = ruling["priority"]
            return false unless priority.is_a?(Integer)

            task.priority = priority
          end
          if ruling.key?("status") && ruling["status"].to_s != task.status
            target = ruling["status"].to_s
            return false unless Task.transition_allowed?(task.status, target)

            task.status = target
          end
          task.next_action_at = nil
          task.last_error = nil
          task.save!
          if ruling["dispatch"]
            DispatchService.new(event_sink: @event_sink, clock: @clock).dispatch(task, now: now)
          end
          if ruling["reply"].is_a?(Hash)
            create_reply_action(task, ruling["reply"])
          end
          true
        end
      end
    rescue StandardError
      false
    end

    def create_reply_action(task, reply)
      r = reply.transform_keys(&:to_s)
      plugin = r["plugin"].to_s
      operation = r["operation"].to_s
      return unless OutboundAction::OPERATIONS.include?(operation)

      resource = r["resource_id"].to_s.presence || task.source_resource_id
      input = { "resource_id" => resource, "body" => r["body"].to_s,
                "scope" => task.source_resource_id }
      OutboundAction.create!(
        plugin: plugin, operation: operation, input: input,
        idempotency_key: "triage-#{task.id}-#{SecureRandom.uuid}",
        status: "pending", task: task
      )
    end

    # Explicit demo-mode fallback only: inbox tasks go ready with the best
    # suggested priority. Production without a policy leaves tasks in inbox.
    def apply_demo_fallback(tasks, now)
      triaged = 0
      tasks.each do |task|
        Task.transaction do
          task.with_lock do
            suggestion = task.task_feedbacks.unprocessed.where.not(suggested_priority: nil)
                              .maximum(:suggested_priority)
            task.priority = suggestion unless suggestion.nil?
            task.transition_to!("ready") if task.status == "inbox"
            task.update!(next_action_at: nil, last_error: nil)
            triaged += 1
          end
        end
      end
      mark_feedback_processed(tasks, now)
      [triaged, 0]
    end

    def backoff_tasks(tasks, now, error)
      tasks.each do |task|
        Task.transaction do
          task.with_lock do
            task.update!(last_error: error.to_s[0, 2000], next_action_at: now + 3600)
          end
        end
      end
    end

    def mark_feedback_processed(tasks, now)
      ids = tasks.map(&:id)
      TaskFeedback.unprocessed.where(task_id: ids).update_all(processed_at: now) # rubocop:disable Rails/SkipsModelValidations
    end

    def build_prompt(tasks)
      lines = tasks.map do |task|
        feedback = task.task_feedbacks.unprocessed.order(:created_at).limit(5)
        suggestions = feedback.map { |f| "feedback(#{f.author}): #{f.body.to_s[0, 500]}" }
        "task_id=#{task.id} status=#{task.status} priority=#{task.priority} " \
          "title=#{task.title.to_s[0, 200]} source=#{task.source_plugin}:#{task.source_resource_id} " \
          "feedback=[#{suggestions.join(" | ")}]"
      end
      <<~PROMPT
        You are the coordination triage for pending tasks. Decide priority (higher first),
        next status (only inbox->ready, inbox->cancelled, ready->running, ready->cancelled,
        failed->ready, running/waiting_* transitions per policy), whether to dispatch an
        execution run, and optional human-facing replies. Unknown task ids, operations,
        and transitions are rejected. Respond with the required schema only.
        #{lines.join("\n")}
      PROMPT
    end

    def ensure_workspace(layer)
      root = WorkflowSettings.execution_root
      dir = File.join(root, "policy-#{layer}")
      FileUtils.mkdir_p(dir)
      dir
    end

    def title_from(event)
      payload = event.payload.is_a?(Hash) ? event.payload.transform_keys(&:to_s) : {}
      title = payload["title"] || payload["subject"] || body_from(event).lines.first
      title.to_s.strip[0, 200].presence || "#{event.plugin} #{event.resource_id}"
    end

    def body_from(event)
      payload = event.payload.is_a?(Hash) ? event.payload.transform_keys(&:to_s) : {}
      (payload["body"] || payload["text"] || "").to_s[0, 4000]
    end

    def safe_message(error)
      error.message.to_s[0, 300]
    end
  end
end
