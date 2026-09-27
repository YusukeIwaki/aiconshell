# frozen_string_literal: true

require "json_schemer"

module Coordination
  # Persists one validated admin coordination result (issue #11):
  # `{summary, actions: [{plugin, operation, input}]}`. Only tasks with a
  # trusted persisted admin origin are eligible; ordinary external tasks are
  # rejected. Every action is validated before any task/feedback mutation,
  # then the whole batch, result/state/batch metadata, and exact feedback
  # acknowledgements commit atomically under the task lock. No execution is
  # enqueued and no TaskRun is created here.
  #
  # Triage calls this under its task/policy/feedback snapshots:
  #
  #   Coordination::ResultService.new.apply(
  #     task_id: task.id, task_version: task.lock_version,
  #     feedback_ids: [1, 2], policy: coordination_policy,
  #     result: { "summary" => "...", "actions" => [...] })
  #
  # Idempotency keys are stable derivations of task_id, the snapshotted
  # lock_version, and the 1-based action ordinal. A no-action result
  # completes the task as done with the stored summary; results with
  # actions move the task to waiting_delivery, never directly to done.
  class ResultService
    Result = Struct.new(:ok, :code, :action_index, keyword_init: true)

    RESULT_SCHEMA = {
      "type" => "object", "additionalProperties" => false,
      "properties" => {
        "summary" => { "type" => "string", "minLength" => 1, "maxLength" => 2000 },
        "actions" => {
          "type" => "array", "maxItems" => 20,
          "items" => {
            "type" => "object", "additionalProperties" => false,
            "properties" => {
              "plugin" => { "type" => "string", "minLength" => 1 },
              "operation" => { "type" => "string", "minLength" => 1 },
              "input" => { "type" => "object" }
            },
            "required" => %w[plugin operation input]
          }
        }
      },
      "required" => %w[summary actions]
    }.freeze

    # Explicit from-states for admin results. Deliberately narrower than the
    # shared Task::TRANSITIONS map, which stays unchanged for ordinary tasks.
    RESULT_SOURCE_STATUSES = %w[inbox ready waiting_human waiting_review failed].freeze

    def initialize(registry: Aiconshell::Plugins::Registry.default,
                   event_sink: WorkflowEvents, clock: Time, allowed_scopes: nil,
                   oauth_credential_provider: nil)
      @validator = Interaction::ActionValidator.new(registry: registry, allowed_scopes: allowed_scopes)
      @event_sink = event_sink
      @clock = clock
      @oauth_credential_provider = oauth_credential_provider
    end

    # `oauth_bindings:` optionally carries the read-time snapshots fixed
    # during typed reads (plugin id -> secret-free binding hash). When
    # present, a disconnect/replacement between the read and this result
    # rejects instead of continuing as a different principal. The AI never
    # supplies bindings; the application fixes them. Each OAuth action's
    # snapshot is stored on its OutboundAction for enqueue→delivery fencing.
    def apply(task_id:, task_version:, feedback_ids:, policy:, result:, oauth_bindings: nil)
      value = result.is_a?(Hash) ? result.deep_stringify_keys : nil
      unless value.is_a?(Hash) && JSONSchemer.schema(RESULT_SCHEMA).valid?(value) &&
          value["summary"].strip.present? && !value["summary"].include?("\u0000")
        emit_rejected(task_id, :invalid_result)
        return Result.new(ok: false, code: :invalid_result)
      end

      batch_key = "result-#{task_id}-#{task_version}"
      actions = value.fetch("actions")

      Task.transaction(requires_new: true) do
        task = Task.lock.find_by(id: task_id)
        return reject(task_id, :unknown_task) unless task
        return reject(task_id, :duplicate_result) if task.delivery_batch_key == batch_key
        return reject(task_id, :stale_task) unless task.lock_version == task_version
        return reject(task_id, :stale_policy) unless policy_current?(policy)
        return reject(task_id, :not_admin_origin) unless task.admin_request?
        return reject(task_id, :task_running) if task_running?(task)
        unless RESULT_SOURCE_STATUSES.include?(task.status)
          code = task.status == "waiting_delivery" ? :batch_active : :terminal_task
          return reject(task_id, code)
        end
        return reject(task_id, :outstanding_actions) if outstanding_actions?(task)
        if %w[waiting_human waiting_review].include?(task.status)
          pending = task.task_feedbacks.unprocessed.where(author_type: "human", id: Array(feedback_ids))
          return reject(task_id, :feedback_required) unless pending.exists?
        end

        # One verified binding per OAuth plugin, fixed here and reused
        # for every create below: validate-plus-create never re-resolves
        # (a second lookup could observe a replaced connection and store
        # an unchecked or foreign snapshot). A disconnect/replacement
        # between the typed read and this result rejects instead of
        # continuing as another principal.
        verified_bindings = {}
        actions.each_with_index do |action, index|
          verdict = @validator.validate(plugin: action["plugin"], operation: action["operation"], input: action["input"])
          unless verdict.ok?
            emit_rejected(task.id, verdict.code, action_index: index, action_count: actions.size)
            return Result.new(ok: false, code: verdict.code, action_index: index)
          end
          if Interaction::OauthContext.oauth_plugin?(action["plugin"].to_s)
            plugin_name = action["plugin"].to_s
            unless verified_bindings.key?(plugin_name)
              binding_result = oauth_binding_for(plugin_name, oauth_bindings)
              unless binding_result[:ok]
                emit_rejected(task.id, binding_result[:code], action_index: index, action_count: actions.size)
                return Result.new(ok: false, code: binding_result[:code], action_index: index)
              end
              verified_bindings[plugin_name] = binding_result[:binding]
            end
          end
        end

        now = current_time
        actions.each_with_index do |action, index|
          attrs = {
            plugin: action["plugin"].to_s, operation: action["operation"].to_s,
            input: action["input"].deep_stringify_keys,
            idempotency_key: "#{batch_key}-#{index + 1}",
            delivery_batch_key: batch_key, status: "pending", task: task
          }
          if Interaction::OauthContext.oauth_plugin?(action["plugin"].to_s)
            stored = verified_bindings[action["plugin"].to_s]
            attrs[:oauth_binding] = stored if OutboundAction.column_names.include?("oauth_binding") && !stored.nil?
          end
          OutboundAction.create!(attrs)
        end
        # Direct assignment under an explicit allowlist: the shared transition
        # map stays unchanged so ordinary external tasks gain no new edges.
        task.status = actions.empty? ? "done" : "waiting_delivery"
        task.coordination_result = { "summary" => value.fetch("summary"), "action_count" => actions.size }
        task.delivery_batch_key = batch_key
        task.next_action_at = nil
        task.last_error = nil
        task.save!
        task.touch(time: now)
        TaskFeedback.unprocessed.where(task_id: task.id, author_type: "human", id: Array(feedback_ids)).update_all(processed_at: now)
        @event_sink.emit(layer: "coordination", kind: "result.applied", message: "Admin result applied",
                         task_id: task.id,
                         data: { action_count: actions.size, status: task.status, task_version: task_version })
        Result.new(ok: true, code: :ok)
      end
    rescue ActiveRecord::RecordNotUnique
      # A concurrent identical application won the idempotency-key race.
      reject(task_id, :duplicate_result)
    rescue ActiveRecord::RecordInvalid, SystemStackError
      reject(task_id, :invalid_result)
    end

    private

    def oauth_provider
      @oauth_credential_provider ||= begin
        Oauth::CredentialProvider.new(event_sink: @event_sink)
      rescue StandardError
        nil
      end
    end

    # Fixes the trusted binding for one OAuth action. When read-time
    # snapshots are supplied, the current connection must still match them;
    # otherwise the result stops instead of continuing as another principal.
    # Refresh never changes the generation (see TokenService), so a plain
    # refresh does not invalidate the snapshot.
    def oauth_binding_for(plugin, read_bindings)
      provider = oauth_provider
      return { ok: false, code: :credentials_missing } if provider.nil?

      begin
        current = Interaction::OauthContext.snapshot_binding(plugin, credential_provider: provider)
      rescue Oauth::CredentialProvider::NotConnected
        return { ok: false, code: :not_connected }
      rescue Aiconshell::Oauth::Error
        return { ok: false, code: :not_connected }
      end
      if read_bindings.is_a?(Hash) && read_bindings.key?(plugin.to_s)
        expected = read_bindings[plugin.to_s]
        bound = Aiconshell::Oauth::Binding.from_h(expected)
        current_hash = current.is_a?(Hash) ? current : current.to_h
        return { ok: false, code: :stale_binding } unless bound.matches?(current_hash)
      end
      { ok: true, code: :ok, binding: current }
    end

    def policy_current?(policy)
      return false unless policy.is_a?(LayerPolicy) && policy.id && policy.updated_at && policy.layer == "coordination"

      LayerPolicy.where(id: policy.id, layer: "coordination", enabled: true, updated_at: policy.updated_at).exists?
    end

    def task_running?(task)
      task.status == "running" || task.current_run_id.present? || task.task_runs.active.exists?
    end

    def outstanding_actions?(task)
      task.outbound_actions.where(status: %w[pending sending]).exists?
    end

    def reject(task_id, code)
      emit_rejected(task_id, code)
      Result.new(ok: false, code: code)
    end

    def emit_rejected(task_id, code, action_index: nil, action_count: nil)
      data = { code: code.to_s }
      data[:action_index] = action_index unless action_index.nil?
      data[:action_count] = action_count unless action_count.nil?
      @event_sink.emit(layer: "coordination", kind: "result.rejected", message: "Admin result rejected",
                       task_id: task_id, data: data)
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end
