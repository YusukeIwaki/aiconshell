# frozen_string_literal: true

module Aiconshell
  module Ai
    # Fixed provider catalog. All three providers are always listed and
    # selectable; configured? only diagnoses CLI/auth-location presence.
    class Registry
      ADAPTERS = [ClaudeAdapter, CodexAdapter, MuseAdapter].freeze

      def self.default
        new(config: Config.default)
      end

      attr_reader :config

      def initialize(config: Config.default, adapters: ADAPTERS)
        @config = config
        @adapters = adapters
      end

      # Always ["claude", "codex", "muse"], regardless of configuration.
      def providers
        @adapters.map(&:id)
      end

      # Catalog entries with presence diagnostics. Secrets are never included.
      def catalog
        @adapters.map do |adapter|
          {
            id: adapter.id,
            name: adapter.display_name,
            executable: config.executable_for(adapter.id),
            configured: adapter.configured?(config)
          }
        end
      end

      def configured?(provider)
        adapter_for(provider).configured?(config)
      end

      def diagnose(provider)
        adapter_for(provider).diagnose(config)
      end

      def resolve_executable(provider)
        adapter_for(provider).resolve_executable(config)
      end

      def adapter_for(provider)
        adapter = @adapters.find { |candidate| candidate.id == provider }
        raise UnknownProvider, provider if adapter.nil?

        adapter
      end
    end
  end
end
