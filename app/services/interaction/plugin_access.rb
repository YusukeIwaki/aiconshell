# frozen_string_literal: true

module Interaction
  # Resource destinations and operation capabilities are separate permissions.
  module PluginAccess
    module_function

    def context(plugin, operation, registry:)
      capability = if registry.respond_to?(:catalog)
        entry = registry.catalog.find { |item| item["id"] == plugin.to_s }
        entry&.fetch("operations", [])&.find { |item| item["name"] == operation }&.fetch("scope", nil)
      else
        "#{plugin}:#{operation == 'latest_events' ? 'read' : 'write'}"
      end
      { "scopes" => Array(capability) }
    end

    def destination(plugin, operation, input)
      target = input.fetch(operation == "reply" ? "resource_id" : "scope", "").to_s
      case plugin.to_s
      when "github"
        match = /\A(?:issue|pr):([^\/\s#]+\/[^\/\s#]+)#\d+\z/.match(target)
        match ? match[1] : target
      when "discord"
        match = /\A(?:message|channel):([^\/]+)(?:\/[^\/]+)?\z/.match(target)
        match ? "channel/#{match[1]}" : target
      else
        target # custom plugins can use an exact operator-allowlisted resource
      end
    end

    def self_actor_ids(plugin)
      ENV.fetch("AICONSHELL_SELF_ACTOR_IDS", "").split(",").filter_map do |entry|
        provider, id = entry.strip.split(":", 2)
        id if provider == plugin.to_s && id.present?
      end.uniq
    end
  end
end
