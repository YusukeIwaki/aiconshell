# frozen_string_literal: true

# Thin EventLog facade. Delegates to Aiconshell::Observability when the
# EventLog lane is present; otherwise a no-op. Never raises, never rolls
# back the surrounding business transaction. No prompts, raw CLI output,
# tokens, or secrets are ever passed as data.
module WorkflowEvents
  class << self
    def emit(layer:, kind:, message:, task_id: nil, correlation_id: nil, data: {})
      return nil unless observability?

      Aiconshell::Observability.emit(
        layer: layer.to_s, kind: kind.to_s, message: message.to_s,
        task_id: task_id, correlation_id: correlation_id,
        data: data.is_a?(Hash) ? data : {}
      )
    rescue StandardError => e
      Rails.logger.warn("[workflow-events] emit dropped: #{e.class}") if defined?(Rails)
      nil
    end

    def observability?
      defined?(Aiconshell::Observability) && Aiconshell::Observability.respond_to?(:emit)
    end
  end
end
