# frozen_string_literal: true

module Admin
  # Presentation adapter over the AI lane (issue 4).
  #
  # The provider list is the fixed architecture contract and never depends
  # on local configuration, so unconfigured providers stay selectable.
  # Configuration probing degrades to "unknown" when the AI lane is not
  # loaded yet; it never raises through the caller and never exposes
  # secret contents (diagnostics carry paths and flags only).
  module AiStatus
    PROVIDERS = %w[claude codex muse].freeze

    class << self
      # Test seam: inject a fake registry responding to
      # configured?(provider) / diagnose(provider).
      attr_writer :registry

      def providers
        PROVIDERS
      end

      def known_provider?(value)
        PROVIDERS.include?(value.to_s)
      end

      def registry
        @registry = load_default_registry if @registry.nil? && !defined?(@registry)
        @registry
      end

      def reset!
        remove_instance_variable(:@registry) if defined?(@registry)
      end

      # true/false when the lane is present, nil when unknown.
      def configured?(provider)
        reg = registry
        return nil if reg.nil?

        !!reg.configured?(provider.to_s)
      rescue StandardError
        nil
      end

      # Hash with :id, :configured (true/false/nil), and optional detail
      # keys. Never raises, never carries secrets.
      def diagnosis(provider)
        reg = registry
        return { id: provider.to_s, configured: nil, available: false } if reg.nil?

        detail = reg.diagnose(provider.to_s) || {}
        {
          id: provider.to_s,
          configured: detail[:configured].nil? ? nil : !!detail[:configured],
          executable_found: detail[:executable_found].nil? ? nil : !!detail[:executable_found],
          home_present: detail[:home_present].nil? ? nil : !!detail[:home_present],
          available: true
        }
      rescue StandardError
        { id: provider.to_s, configured: nil, available: false }
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
