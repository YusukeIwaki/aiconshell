# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Execution
  # Leases one persisted TaskRun, executes the bounded AI call inside an
  # isolated workspace, and hands the structured result back to Coordination.
  # This namespace never updates Task rows and never calls external plugins:
  # workers receive normalized task data and return structured results only.
  #
  # Lease discipline: the lease (default 1800s) exceeds the bounded AI
  # runtime (default 600s); heartbeats extend it when operators configure a
  # tighter lease. DB locks are never held across the subprocess call.
  class RunnerService
    Result = Struct.new(:ok, :code, keyword_init: true)

    RESULT_SCHEMA = {
      "type" => "object",
      "properties" => {
        "outcome" => { "type" => "string" },
        "summary" => { "type" => "string" },
        "reply_body" => { "type" => "string" }
      },
      "required" => %w[outcome summary]
    }.freeze

    def initialize(ai_runner: nil, event_sink: WorkflowEvents, clock: Time)
      @ai_runner = ai_runner || default_runner
      @event_sink = event_sink
      @clock = clock
    end

    def call(run_id)
      now = current_time
      leased = acquire_lease(run_id, now)
      return Result.new(ok: false, code: leased) if leased.is_a?(Symbol) && leased != :leased

      run_id, lease_token, snapshot = leased
      workspace = build_workspace(snapshot[:task_id], run_id)
      if workspace.nil?
        Coordination::CompletionService.new(event_sink: @event_sink, clock: @clock).fail_run(
          run_id: run_id, lease_token: lease_token,
          error_code: :workspace_rejected, error: "workspace escaped the execution root"
        )
        return Result.new(ok: false, code: :workspace_rejected)
      end

      if @ai_runner.nil?
        Coordination::CompletionService.new(event_sink: @event_sink, clock: @clock).fail_run(
          run_id: run_id, lease_token: lease_token,
          error_code: :provider_not_configured, error: "execution AI runner is not available"
        )
        return Result.new(ok: false, code: :provider_not_configured)
      end

      heartbeat(run_id, lease_token)
      result = invoke_ai(snapshot, workspace)
      if result[:ok]
        Coordination::CompletionService.new(event_sink: @event_sink, clock: @clock).complete(
          run_id: run_id, lease_token: lease_token, result: result[:value]
        )
        Result.new(ok: true, code: :ok)
      else
        Coordination::CompletionService.new(event_sink: @event_sink, clock: @clock).fail_run(
          run_id: run_id, lease_token: lease_token,
          error_code: result[:code], error: result[:error]
        )
        Result.new(ok: false, code: result[:code])
      end
    end

    # Extends the lease of a live run. Called before the AI invocation and
    # available to long-running adapters that report progress.
    def heartbeat(run_id, lease_token)
      now = current_time
      TaskRun.transaction do
        run = TaskRun.lock.find_by(id: run_id)
        return false if run.nil? || run.lease_token != lease_token || run.terminal?

        run.update!(lease_expires_at: now + WorkflowSettings.lease_seconds, heartbeat_at: now)
        true
      end
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

    # Leases a pending run. Duplicate jobs for an already leased/terminal run
    # are rejected without touching the lease.
    def acquire_lease(run_id, now)
      TaskRun.transaction do
        run = TaskRun.lock.find_by(id: run_id)
        return :unknown_run if run.nil?
        return :duplicate_job unless run.status == "pending"

        token = SecureRandom.uuid
        run.update!(status: "running", lease_token: token,
                    lease_expires_at: now + WorkflowSettings.lease_seconds,
                    started_at: now, heartbeat_at: now)
        snapshot = {
          task_id: run.task_id, provider: run.provider, model: run.model,
          effort: run.effort, instructions: run.instructions,
          title: run.task.title, description: run.task.description, priority: run.task.priority
        }
        @event_sink.emit(layer: "execution", kind: "run.leased",
                         message: "Run #{run.id} leased", task_id: run.task_id,
                         data: { run_id: run.id })
        [run.id, token, snapshot]
      end
    end

    def build_workspace(task_id, run_id)
      root = File.expand_path(WorkflowSettings.execution_root)
      FileUtils.mkdir_p(root)
      dir = File.expand_path(File.join(root, "task_#{task_id}", "run_#{run_id}"))
      return nil unless dir == root || dir.start_with?("#{root}/")

      FileUtils.mkdir_p(dir)
      dir
    rescue StandardError
      nil
    end

    # Normalized task data only; no plugin handles cross this boundary.
    def invoke_ai(snapshot, workspace)
      prompt = <<~PROMPT
        You are the execution worker for one task. Use only the workspace
        #{workspace}. Do not call external services. Return the schema only.
        title=#{snapshot[:title].to_s[0, 200]}
        priority=#{snapshot[:priority]}
        description=#{snapshot[:description].to_s[0, 4000]}
      PROMPT
      value = @ai_runner.call(
        provider: snapshot[:provider], prompt: prompt, schema: RESULT_SCHEMA,
        workspace: workspace, layer: "execution",
        model: snapshot[:model], effort: snapshot[:effort], instructions: snapshot[:instructions],
        timeout: WorkflowSettings.ai_timeout_seconds
      )
      { ok: true, value: value }
    rescue StandardError => e
      { ok: false, code: error_code(e), error: "execution AI failed (#{error_code(e)}): #{safe_message(e)}" }
    end

    def error_code(error)
      name = error.class.name.to_s
      return :provider_not_configured if name.match?(/NotConfigured|NotFound|Unknown/i)
      return :provider_timeout if name.match?(/Timeout/i)
      return :provider_invalid_output if name.match?(/InvalidOutput|Schema|Validation/i)

      :provider_error
    end

    def safe_message(error)
      error.message.to_s[0, 300]
    end
  end
end
