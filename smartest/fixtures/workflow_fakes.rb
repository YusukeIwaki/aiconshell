# frozen_string_literal: true

# Deterministic test-only doubles for the plugin and AI ports. These fakes
# are injected explicitly in tests; production services default to the real
# port constants and never fall back to these silently.
module WorkflowFakes
  class FakeNotConfigured < StandardError; end
  class FakeTimeout < StandardError; end
  class FakeTransportError < StandardError; end
  class FakeUnknownPlugin < StandardError; end

  # Scripted plugin registry. Program latest_events payloads per scope and
  # capture every invocation for assertions.
  class FakePluginRegistry
    attr_reader :invocations, :sent

    # Catalog metadata mirroring the real registry contract
    # (id/operations with input_schema/output_schema/scope/read_only,
    # required_env, configured). This scripted fixture declares permissive
    # input shapes for its synthetic IDs; real-plugin tests exercise strict
    # production schemas and destination formats separately.
    FAKE_CATALOG = {
      "github" => %w[latest_events reply create_issue],
      "discord" => %w[latest_events reply send_message create_issue]
    }.freeze

    def initialize(events_by_scope: {}, errors: {})
      @events_by_scope = events_by_scope
      @errors = errors
      @invocations = []
      @sent = []
    end

    def catalog
      FAKE_CATALOG.map do |id, operations|
        {
          "id" => id,
          "operations" => operations.map { |name| fake_operation(id, name) },
          "required_env" => [],
          "configured" => true
        }
      end
    end

    def invoke(plugin:, operation:, input:, context: {})
      input = input.transform_keys(&:to_s) if input.is_a?(Hash)
      @invocations << { plugin: plugin.to_s, operation: operation.to_s, input: input, context: context }
      key = "#{plugin}##{operation}"
      raise @errors[key] if @errors.key?(key)

      case operation.to_s
      when "latest_events"
        scope = input["scope"].to_s
        raise FakeUnknownPlugin, "unknown scope #{scope}" if @events_by_scope.key?(:__strict__) && !@events_by_scope.key?(scope)

        { "events" => @events_by_scope.fetch(scope, []), "cursor" => { "next" => "cursor-#{scope}-2" } }
      when "reply", "send_message", "create_issue"
        external_id = "ext-#{@sent.size + 1}"
        @sent << { plugin: plugin.to_s, operation: operation.to_s, input: input }
        { "external_id" => external_id, "url" => nil }
      else
        raise FakeUnknownPlugin, "unknown operation #{operation}"
      end
    end

    def validate_input(plugin:, operation:, input:, context: {})
      require_relative "../../lib/aiconshell/plugins"
      entry = catalog.find { |item| item["id"] == plugin.to_s }
      raise Aiconshell::Plugins::UnknownPlugin.new(plugin) unless entry

      op = entry.fetch("operations").find { |item| item["name"] == operation.to_s }
      raise Aiconshell::Plugins::UnknownOperation.new(plugin: plugin, operation: operation) unless op
      if op["unsupported"]
        raise Aiconshell::Plugins::UnsupportedOperation.new(plugin: plugin, operation: operation, reason: op["reason"])
      end
      if context["scopes"] && !context["scopes"].include?(op["scope"])
        raise Aiconshell::Plugins::PermissionDenied.new(plugin: plugin, operation: operation, required_scope: op["scope"])
      end
      unless Aiconshell::Plugins::Schemas.valid?(op["input_schema"], input)
        raise Aiconshell::Plugins::InputInvalid.new(plugin: plugin, operation: operation, details: ["invalid fixture input"])
      end
      input
    end

    private

    def fake_operation(plugin, name)
      entry = {
        "name" => name,
        "input_schema" => fake_input_schema(name),
        "output_schema" => fake_output_schema(name),
        "scope" => "#{plugin}:#{name == 'latest_events' ? 'read' : 'write'}",
        "read_only" => name == "latest_events"
      }
      if plugin == "discord" && name == "create_issue"
        entry["unsupported"] = true
        entry["reason"] = "Discord has no issue tracker"
      end
      entry
    end

    def fake_input_schema(name)
      base = case name
      when "latest_events"
        { "required" => %w[scope],
          "properties" => { "scope" => { "type" => "string", "minLength" => 1 } } }
      when "reply"
        { "required" => %w[resource_id body],
          "properties" => {
            "resource_id" => { "type" => "string", "minLength" => 1 },
            "body" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 }
          } }
      when "create_issue"
        { "required" => %w[scope title body],
          "properties" => {
            "scope" => { "type" => "string", "minLength" => 1 },
            "title" => { "type" => "string", "minLength" => 1, "maxLength" => 512 },
            "body" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 }
          } }
      when "send_message"
        { "required" => %w[scope body],
          "properties" => {
            "scope" => { "type" => "string", "minLength" => 1 },
            "body" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 }
          } }
      end
      { "type" => "object", "required" => base["required"],
        "properties" => base["properties"], "additionalProperties" => true }
    end

    def fake_output_schema(name)
      return { "type" => "object" } if name == "latest_events"

      {
        "type" => "object", "required" => %w[external_id url],
        "properties" => {
          "external_id" => { "type" => "string", "minLength" => 1 },
          "url" => { "type" => %w[string null] }
        },
        "additionalProperties" => false
      }
    end

    def self.human_event(event_id: "evt-1", fingerprint: "fp-1", resource_id: "issue-1",
                         actor_id: "alice", body: "please fix the login bug",
                         occurred_at: "2026-09-26T00:00:00Z")
      {
        "event_id" => event_id, "fingerprint" => fingerprint, "event_type" => "message",
        "resource_id" => resource_id, "actor_id" => actor_id, "actor_type" => "human",
        "occurred_at" => occurred_at, "payload" => { "body" => body, "title" => body.lines.first.to_s[0, 80] }
      }
    end

    def self.bot_event(event_id: "evt-bot-1", fingerprint: "fp-bot-1", resource_id: "issue-1")
      human_event(event_id: event_id, fingerprint: fingerprint, resource_id: resource_id,
                  actor_id: "aiconshell-bot", body: "automated status ping")
        .merge("actor_type" => "bot")
    end
  end

  # Scripted credential source standing in for the database-backed
  # Accounts module. Maps plugin id to an env-shaped credential hash;
  # unknown plugins read as unconfigured (empty env).
  class FakeCredentialSource
    def initialize(envs = {})
      @envs = envs.transform_keys(&:to_s)
    end

    def env_for(plugin)
      @envs.fetch(plugin.to_s, {})
    end

    def configured?(plugin)
      !env_for(plugin).empty?
    end
  end

  # Scripted AI runner. Program one answer (or error) per layer.
  class FakeAiRunner
    attr_reader :calls

    def initialize(answers: {}, errors: {})
      @answers = answers
      @errors = errors
      @calls = []
    end

    def call(provider:, prompt:, schema:, workspace:, layer:, model: nil, effort: nil,
             instructions: nil, timeout: nil)
      @calls << { provider: provider, layer: layer.to_s, prompt: prompt, workspace: workspace,
                  model: model, effort: effort }
      raise @errors[layer.to_s] if @errors.key?(layer.to_s)
      raise @errors["*"] if @errors.key?("*")

      answer = @answers[layer.to_s]
      raise FakeNotConfigured, "no fake answer for layer #{layer}" if answer.nil?

      answer
    end
  end

  # Capturing event sink for assertions.
  class FakeEventSink
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(layer:, kind:, message:, task_id: nil, correlation_id: nil, data: {})
      @events << { layer: layer.to_s, kind: kind.to_s, message: message.to_s,
                   task_id: task_id, data: data }
      { "event_id" => "evt-#{@events.size}" }
    end

    def kinds
      @events.map { |e| e[:kind] }
    end
  end
end
