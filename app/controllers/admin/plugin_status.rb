# frozen_string_literal: true

module Admin
  # Presentation adapter over the plugins lane (issue 3).
  #
  # The catalog carries environment variable *names* and a configured flag
  # only; values are never exposed. All failures degrade to an empty
  # catalog plus a caller-visible error string so one broken plugin lane
  # never crashes the whole admin console.
  module PluginStatus
    CatalogResult = Struct.new(:entries, :available, :error, keyword_init: true)

    class << self
      # Test seam: inject a fake registry responding to #catalog.
      attr_writer :registry

      def registry
        @registry = load_default_registry if @registry.nil? && !defined?(@registry)
        @registry
      end

      def reset!
        remove_instance_variable(:@registry) if defined?(@registry)
      end

      def catalog
        reg = registry
        return CatalogResult.new(entries: [], available: false, error: nil) if reg.nil?

        CatalogResult.new(entries: Array(reg.catalog), available: true, error: nil)
      rescue StandardError => e
        CatalogResult.new(entries: [], available: true, error: e.class.name)
      end

      private

      def load_default_registry
        require "aiconshell/plugins" unless defined?(Aiconshell::Plugins::Registry)
        return nil unless defined?(Aiconshell::Plugins::Registry)

        Aiconshell::Plugins::Registry.default
      rescue LoadError, StandardError
        nil
      end
    end
  end
end
