# frozen_string_literal: true

require "fileutils"
require "json_schemer"
require "securerandom"

module Interaction
  # A leased outbound intent. Only explicit rate-limit rejections are retried
  # automatically after a request starts; ambiguous delivery requires review.
  class OutboundService
    Result = Struct.new(:ok, :code, keyword_init: true)
    DRAFT_SCHEMA = {
      "type" => "object", "required" => ["body"], "additionalProperties" => false,
      "properties" => { "body" => { "type" => "string", "minLength" => 1, "maxLength" => 4000 } }
    }.freeze

    def initialize(registry: Aiconshell::Plugins::Registry.default,
                   ai_runner: Aiconshell::Ai::Runner.new, event_sink: WorkflowEvents, clock: Time)
      @registry, @ai_runner, @event_sink, @clock = registry, ai_runner, event_sink, clock
    end

    def call(action_id)
      claimed = claim(action_id)
      return Result.new(ok: false, code: claimed) if claimed.is_a?(Symbol)

      token, snapshot = claimed
      request_started = false
      input = snapshot.fetch(:input).transform_keys(&:to_s)
      scope = PluginAccess.destination(snapshot[:plugin], snapshot[:operation], input)
      unless WorkflowSettings.scope_allowed?(snapshot[:plugin], scope)
        return settle(action_id, token, status: "failed", code: :scope_not_allowed)
      end
      if snapshot[:plugin] == "jira" && PluginAccess.self_actor_ids("jira").empty?
        return settle(action_id, token, status: "failed", code: :self_actor_not_configured)
      end
      validator = ActionValidator.new(registry: @registry)
      checked = validator.validate(plugin: snapshot[:plugin], operation: snapshot[:operation], input: input)
      return settle(action_id, token, status: "failed", code: checked.code) unless checked.ok?

      operation = registered_operation(snapshot[:plugin], snapshot[:operation])
      # Exact registered input schema; the full input (including custom
      # required fields) is preserved for the handler, never sliced.
      input = draft(input) if %w[reply send_message].include?(snapshot[:operation])
      checked = validator.validate(plugin: snapshot[:plugin], operation: snapshot[:operation], input: input)
      return settle(action_id, token, status: "failed", code: checked.code) unless checked.ok?

      unless start_request(action_id, token)
        return Result.new(ok: false, code: :stale_delivery)
      end
      request_started = true
      output = @registry.invoke(plugin: snapshot[:plugin], operation: snapshot[:operation],
        input: input, context: PluginAccess.context(snapshot[:plugin], snapshot[:operation], registry: @registry))
      unless Aiconshell::Plugins::Schemas.error_details(operation["output_schema"], output).empty? &&
          output.is_a?(Hash) && output["external_id"].is_a?(String) && output["external_id"].present? &&
          (output["url"].nil? || output["url"].is_a?(String))
        return settle(action_id, token, status: "uncertain", code: :invalid_delivery_response)
      end
      settle(action_id, token, status: "sent", code: :ok,
        external_id: output["external_id"], url: output["url"])
    rescue Aiconshell::Plugins::RateLimited => error
      delay = [[error.retry_after.to_i, 30].max, 21_600].min
      settle(action_id, token, status: "pending", code: :rate_limited, retry_after: delay)
    rescue StandardError => error
      # Never persist provider/transport error text (it can echo credentials).
      rejected = error.class.name.match?(/Unknown|Unsupported|InputInvalid|CredentialsMissing|PermissionDenied|HostRejected/)
      rejected ||= error.respond_to?(:status) && (400..499).cover?(error.status.to_i)
      state = request_started && !rejected ? "uncertain" : "failed"
      settle(action_id, token, status: state,
        code: state == "uncertain" ? :delivery_uncertain : :delivery_rejected)
    end

    # No resend after a crashed HTTP request: we cannot know whether the remote
    # server accepted it. Crashes during local drafting may safely retry.
    def recover_expired!(limit: 100)
      OutboundAction.where(status: "sending").where("lease_expires_at <= ?", now).limit(limit).find_each do |action|
        action.with_lock do
          next unless action.status == "sending" && action.lease_expires_at && action.lease_expires_at <= now

          uncertain = action.request_started_at.present?
          action.update!(status: uncertain ? "uncertain" : "pending",
            error_code: uncertain ? "delivery_uncertain" : "draft_interrupted",
            error: uncertain ? "Delivery outcome requires operator review" : nil,
            lease_token: nil, lease_expires_at: nil, next_attempt_at: now + 30)
        end
      end
    end

    private

    def now = @clock.respond_to?(:current) ? @clock.current : @clock.now

    def claim(id)
      OutboundAction.transaction do
        action = OutboundAction.lock.find_by(id: id)
        return :unknown_action unless action
        return :duplicate_delivery unless action.status == "pending"
        return :not_due if action.next_attempt_at && action.next_attempt_at > now
        if action.attempts >= WorkflowSettings.max_action_attempts
          action.update!(status: "failed", error_code: "attempts_exhausted", error: "Delivery attempts exhausted")
          return :attempts_exhausted
        end
        token = SecureRandom.uuid
        action.update!(status: "sending", attempts: action.attempts + 1, last_attempt_at: now,
          lease_token: token, lease_expires_at: now + WorkflowSettings.ai_timeout_seconds + 120,
          request_started_at: nil, next_attempt_at: nil)
        [token, { plugin: action.plugin, operation: action.operation, input: action.input.deep_dup }]
      end
    end

    def start_request(id, token)
      OutboundAction.transaction do
        action = OutboundAction.lock.find(id)
        return false unless action.status == "sending" && action.lease_token == token && action.lease_expires_at > now

        action.update!(request_started_at: now)
        true
      end
    end

    def settle(id, token, status:, code:, external_id: nil, url: nil, retry_after: nil)
      return Result.new(ok: false, code: code) unless token.is_a?(String)

      OutboundAction.transaction do
        action = OutboundAction.lock.find_by(id: id)
        return Result.new(ok: false, code: :stale_delivery) unless action && action.status == "sending" && action.lease_token == token

        if status == "pending" && action.attempts >= WorkflowSettings.max_action_attempts
          status, code = "failed", :attempts_exhausted
        end
        action.update!(status: status, external_id: external_id, url: url,
          error_code: code == :ok ? nil : code.to_s,
          error: code == :ok ? nil : "Outbound delivery: #{code}",
          lease_token: nil, lease_expires_at: nil,
          next_attempt_at: status == "pending" ? now + (retry_after || 60) : nil)
        @event_sink.emit(layer: "interaction", kind: "outbound.#{status}",
          message: "Outbound action #{status}", task_id: action.task_id,
          data: { action_id: action.id, code: code.to_s })
        Result.new(ok: status == "sent", code: code)
      end
    end

    def registry_entry(plugin)
      @registry.catalog.find { |item| item["id"] == plugin.to_s }
    end

    def registered_operation(plugin, operation)
      registry_entry(plugin)&.fetch("operations", [])&.find { |item| item["name"] == operation.to_s }
    end

    def draft(input)
      policy = LayerPolicy.enabled_for("interaction")
      return input unless policy

      FileUtils.mkdir_p(WorkflowSettings.execution_root, mode: 0700)
      root = File.realpath(WorkflowSettings.execution_root)
      path = File.join(root, "policy-interaction")
      FileUtils.mkdir_p(path, mode: 0700)
      workspace = File.realpath(path)
      raise ArgumentError, "invalid policy workspace" unless workspace.start_with?(root + File::SEPARATOR)

      output = @ai_runner.call(provider: policy.provider, layer: "interaction",
        prompt: "Draft a concise reply preserving these facts. Do not add promises:\n#{input.fetch('body')}",
        schema: DRAFT_SCHEMA, workspace: workspace, model: policy.model, effort: policy.effort,
        instructions: policy.instructions, timeout: WorkflowSettings.ai_timeout_seconds)
      raise ArgumentError, "invalid draft" unless JSONSchemer.schema(DRAFT_SCHEMA).valid?(output)

      input.merge("body" => output.fetch("body"))
    end
  end
end
