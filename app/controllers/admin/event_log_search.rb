# frozen_string_literal: true

module Admin
  # Presentation adapter over the EventLog lane (issue 5).
  #
  # Delegates to the Rails-facing EventLogging::Search when it is loaded,
  # else to Aiconshell::Observability directly, else raises NotConfigured
  # so the controller can render an informative status instead of a 500.
  class EventLogSearch
    class NotConfigured < StandardError; end

    class << self
      # Test seam: inject a fake backend responding to .search with the
      # Observability.search keyword signature.
      attr_writer :backend

      def backend
        @backend = load_default_backend if @backend.nil? && !defined?(@backend)
        @backend
      end

      def reset!
        remove_instance_variable(:@backend) if defined?(@backend)
      end

      def search(query: nil, layer: nil, kind: nil, task_id: nil,
                 correlation_id: nil, since: nil, until_time: nil, limit: 50)
        target = backend
        raise NotConfigured, "EventLog search is not configured" if target.nil?

        Array(target.search(
          query:, layer:, kind:, task_id:, correlation_id:,
          since:, until_time:, limit:
        ))
      end

      private

      def load_default_backend
        return EventLogging::Search if defined?(EventLogging::Search)
        if defined?(Aiconshell::Observability) && Aiconshell::Observability.respond_to?(:search)
          return Aiconshell::Observability
        end

        nil
      end
    end
  end
end
