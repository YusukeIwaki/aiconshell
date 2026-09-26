# frozen_string_literal: true

require "fileutils"

module Interaction
  # Delivers coordination-owned outbound actions through allowlisted plugin
  # scopes. AI-supplied destinations are never trusted alone: the plugin,
  # operation, and scope are re-validated against configuration and per
  # operation schemas here.
  #
  # When the interaction LayerPolicy is enabled, reply/send bodies are
  # interpreted/drafted through that policy before sending; otherwise the
  # coordination-provided body is sent as-is. A policy naming an unconfigured
  # provider fails the action structurally instead of silently falling back.
  class OutboundService
    Result = Struct.new(:ok, :code, keyword_init: true)

    DRAFT_SCHEMA = {
      "type" => "object",
      "properties" => { "body" => { "type" => "string" } },
      "required" => ["body"]
    }.freeze

    def initialize(registry: nil, ai_runner: nil, event_sink: WorkflowEvents, clock: Time)
      @registry = registry || default_registry
      @ai_runner = ai_runner || default_runner
      @event_sink = event_sink
      @clock = clock
    end

    def call(action_id)
      now = current_time
      claimed = claim(action_id, now)
      return Result.new(ok: false, code: claimed) if claimed.is_a?(Symbol)

      action_id, snapshot = claimed
      outcome = deliver(snapshot, now)
      settle(action_id, outcome, now)
      Result.new(ok: outcome[:ok], code: outcome[:code])
    end

    private

    def default_registry
      return nil unless defined?(Aiconshell::Plugins::Registry)

      Aiconshell::Plugins::Registry.default
    rescue StandardError
      nil
    end

    def default_runner
      return nil unless defined?(Aiconshell::Ai::Runner)

      Aiconshell::Ai::Runner.new
    rescue StandardError
      nil
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end

    # Moves pending->sending under a row lock. Anything else is a duplicate.
    def claim(action_id, now)
      OutboundAction.transaction do
        action = OutboundAction.lock.find_by(id: action_id)
        return :unknown_action if action.nil?
        return :duplicate_delivery unless action.status == "pending"
        return :attempts_exhausted if action.attempts >= WorkflowSettings.max_action_attempts

        action.update!(status: "sending", attempts: action.attempts + 1, last_attempt_at: now)
        [action.id, { plugin: action.plugin, operation: action.operation,
                      input: action.input, task_id: action.task_id }]
      end
    end

    # All validation and network I/O happen outside the claim lock.
    def deliver(snapshot, now)
      plugin = snapshot[:plugin].to_s
      operation = snapshot[:operation].to_s
      input = snapshot[:input].is_a?(Hash) ? snapshot[:input].transform_keys(&:to_s) : {}

      scope = input["scope"].to_s
      scope = input["resource_id"].to_s if scope.empty?
      unless OutboundAction::OPERATIONS.include?(operation)
        return { ok: false, code: :unknown_operation, error: "unknown operation #{operation}" }
      end
      unless WorkflowSettings.scope_allowed?(plugin, scope)
        return { ok: false, code: :scope_not_allowed,
                 error: "scope #{plugin}:#{scope} is not allowlisted" }
      end
      validation_error = validate_input(operation, input)
      return { ok: false, code: :input_invalid, error: validation_error } unless validation_error.nil?

      if draftable?(operation)
        drafted = maybe_draft_body(input["body"].to_s)
        return drafted unless drafted[:ok]

        input = input.merge("body" => drafted[:body]) unless drafted[:body].nil?
      end

      if @registry.nil?
        return { ok: false, code: :registry_missing, error: "plugin registry is not available" }
      end

      output = @registry.invoke(
        plugin: plugin, operation: operation,
        input: send_input(operation, input),
        context: { "scopes" => WorkflowSettings.allowed_scopes }
      )
      out = output.is_a?(Hash) ? output.transform_keys(&:to_s) : {}
      { ok: true, code: :ok, external_id: out["external_id"].to_s, url: out["url"] }
    rescue StandardError => e
      if retryable?(e)
        { ok: false, code: :transient_error, error: "#{e.class}: #{e.message.to_s[0, 300]}", retryable: true }
      else
        { ok: false, code: :delivery_rejected, error: "#{e.class}: #{e.message.to_s[0, 300]}" }
      end
    end

    def settle(action_id, outcome, now)
      OutboundAction.transaction do
        action = OutboundAction.lock.find_by(id: action_id)
        return if action.nil?

        if outcome[:ok]
          action.update!(status: "sent", external_id: outcome[:external_id], url: outcome[:url],
                         error: nil, error_code: nil)
          @event_sink.emit(layer: "interaction", kind: "outbound.sent",
                           message: "Outbound action #{action.id} sent",
                           task_id: action.task_id, data: { action_id: action.id })
        elsif outcome[:retryable]
          # Visible and retryable: back to pending for the next delivery pass.
          action.update!(status: "pending", error: outcome[:error].to_s[0, 2000],
                         error_code: outcome[:code].to_s)
          @event_sink.emit(layer: "interaction", kind: "outbound.retryable",
                           message: "Outbound action #{action.id} retryable",
                           task_id: action.task_id, data: { action_id: action.id })
        else
          action.update!(status: "failed", error: outcome[:error].to_s[0, 2000],
                         error_code: outcome[:code].to_s)
          @event_sink.emit(layer: "interaction", kind: "outbound.failed",
                           message: "Outbound action #{action.id} failed",
                           task_id: action.task_id,
                           data: { action_id: action.id, error_code: outcome[:code].to_s })
        end
      end
    end

    def validate_input(operation, input)
      case operation
      when "reply"
        return "reply requires resource_id" if input["resource_id"].to_s.empty?
        return "reply requires body" if input["body"].to_s.strip.empty?
      when "create_issue"
        return "create_issue requires scope" if input["scope"].to_s.empty?
        return "create_issue requires title" if input["title"].to_s.strip.empty?
      when "send_message"
        return "send_message requires scope" if input["scope"].to_s.empty?
        return "send_message requires body" if input["body"].to_s.strip.empty?
      end
      nil
    end

    def send_input(operation, input)
      case operation
      when "reply" then { "resource_id" => input["resource_id"], "body" => input["body"] }
      when "create_issue"
        { "scope" => input["scope"], "title" => input["title"], "body" => input["body"].to_s }
      when "send_message" then { "scope" => input["scope"], "body" => input["body"] }
      else input
      end
    end

    def draftable?(operation)
      %w[reply send_message].include?(operation)
    end

    # Uses the interaction policy when enabled. Returns {ok, body/nil} where
    # body nil means "send the coordination body as-is".
    def maybe_draft_body(body)
      policy = LayerPolicy.enabled_for("interaction")
      return { ok: true, body: nil } if policy.nil?
      return { ok: false, code: :provider_not_configured, error: "interaction AI runner is not available" } if @ai_runner.nil?

      workspace = ensure_workspace
      answer = @ai_runner.call(
        provider: policy.provider,
        prompt: "Draft a concise human-facing reply for this update. Keep facts, no new promises:\n#{body[0, 2000]}",
        schema: DRAFT_SCHEMA, workspace: workspace, layer: "interaction",
        model: policy.model, effort: policy.effort, instructions: policy.instructions,
        timeout: WorkflowSettings.ai_timeout_seconds
      )
      drafted = (answer["body"] || answer[:body]).to_s.strip
      return { ok: false, code: :provider_invalid_output, error: "interaction draft was empty" } if drafted.empty?

      { ok: true, body: drafted[0, 4000] }
    rescue StandardError => e
      { ok: false, code: :provider_not_configured, error: "interaction draft failed: #{e.message.to_s[0, 200]}" }
    end

    def ensure_workspace
      dir = File.join(WorkflowSettings.execution_root, "policy-interaction")
      FileUtils.mkdir_p(dir)
      dir
    end

    def retryable?(error)
      name = error.class.name.to_s
      return false if name.match?(/Unknown|Unsupported|Invalid|NotAllowed|Permission/i)

      true
    end
  end
end
