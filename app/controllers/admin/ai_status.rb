# frozen_string_literal: true

module Admin
  # Presentation adapter for layer policy status.
  #
  # The provider list is the fixed architecture contract and never depends
  # on local configuration, so unconfigured providers stay selectable.
  # Status comes from worker-confirmed snapshots (AiConnection), never from
  # web-local CLI/home probing: the web container has no CLI, so local
  # probing would always misreport "unconfigured".
  #
  # Layer to worker role: interaction/coordination use control, execution
  # uses execution. Each diagnosis carries the role and last checked time.
  module AiStatus
    PROVIDERS = %w[claude codex muse].freeze
    LAYER_ROLES = {
      "interaction" => "control",
      "coordination" => "control",
      "execution" => "execution"
    }.freeze

    class << self
      # Legacy test seam (web-local registry). Diagnosis no longer uses it;
      # kept so old callers resetting it do not crash. New tests create
      # AiConnection snapshots instead.
      attr_writer :registry

      def providers
        PROVIDERS
      end

      def known_provider?(value)
        PROVIDERS.include?(value.to_s)
      end

      def worker_role_for(layer)
        LAYER_ROLES[layer.to_s]
      end

      def registry
        @registry = load_default_registry if @registry.nil? && !defined?(@registry)
        @registry
      end

      def reset!
        remove_instance_variable(:@registry) if defined?(@registry)
      end

      # true/false when the lane is present, nil when unknown. Legacy
      # web-local probing; policy pages no longer use it for display.
      def configured?(provider)
        reg = registry
        return nil if reg.nil?

        !!reg.configured?(provider.to_s)
      rescue StandardError
        nil
      end

      # Worker-snapshot diagnosis. Hash with :id, :worker_role, :state,
      # :checked_at, :error_code, :configured (true/false/nil for badge
      # compat), :available. Never raises, never carries secrets.
      def diagnosis(provider, layer: nil, worker_role: nil)
        id_text = provider.to_s
        role = worker_role&.to_s || LAYER_ROLES[layer.to_s]
        if role.nil? || role.empty?
          return { id: id_text, worker_role: nil, state: "unknown",
                   checked_at: nil, error_code: nil,
                   configured: nil, available: true }
        end

        snapshot = AiConnection.find_by(provider: id_text, worker_role: role)
        if snapshot.nil? || snapshot.checked_at.nil?
          return { id: id_text, worker_role: role, state: "unknown",
                   checked_at: nil, error_code: snapshot&.error_code,
                   configured: nil, available: true }
        end

        state = snapshot.state.to_s
        configured = case state
                     when "connected" then true
                     when "unknown" then nil
                     else false
                     end
        { id: id_text, worker_role: role, state: state,
          checked_at: snapshot.checked_at, error_code: snapshot.error_code,
          configured: configured, available: true }
      rescue StandardError
        { id: provider.to_s, worker_role: worker_role&.to_s || LAYER_ROLES[layer.to_s],
          state: "unknown", checked_at: nil, error_code: nil,
          configured: nil, available: false }
      end

      private

      def load_default_registry
        require "aiconshell/ai" unless defined?(Aiconshell::Ai::Registry)
        return nil unless defined?(Aiconshell::Ai::Registry)

        Aiconshell::Ai::Registry.default
      rescue LoadError, StandardError
        nil
      end
    end
  end
end
