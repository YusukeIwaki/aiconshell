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

    def initialize(events_by_scope: {}, errors: {})
      @events_by_scope = events_by_scope
      @errors = errors
      @invocations = []
      @sent = []
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
