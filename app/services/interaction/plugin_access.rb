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

    # Allowlist namespaces are per plugin id: `jira:PROJ` never
    # authorizes `jira_oauth:PROJ` and vice versa. Delegated OAuth
    # destinations normalize to their own namespace so the operator
    # allowlist (`AICONSHELL_ALLOWED_SCOPES` with `jira_oauth:` /
    # `teams_oauth:` entries) stays separate from the legacy Bot /
    # service-account entries.
    def destination(plugin, operation, input)
      target = input.fetch(operation == "reply" ? "resource_id" : "scope", "").to_s
      case plugin.to_s
      when "github"
        match = /\A(?:issue|pr):([^\/\s#]+\/[^\/\s#]+)#\d+\z/.match(target)
        match ? match[1] : target
      when "jira"
        match = /\Aissue:([A-Za-z][A-Za-z0-9_]*)-\d+\z/.match(target)
        match ? match[1].upcase : target
      when "jira_oauth"
        if operation.to_s == "reply"
          match = /\Aissue:([A-Za-z][A-Za-z0-9_]*)-\d+\z/.match(target)
          match ? match[1].upcase : target
        else
          target.to_s.upcase
        end
      when "teams"
        match = /\A(?:message|channel):([^\/]+)\/([^\/]+)(?:\/[^\/]+)?\z/.match(target)
        match ? "team/#{match[1]}/channel/#{match[2]}" : target
      when "teams_oauth"
        if operation.to_s == "reply"
          channel = /\Amessage:([^\/]+)\/([^\/]+)\/[^\/]+\z/.match(target)
          return "team/#{channel[1]}/channel/#{channel[2]}" if channel

          chat = /\Achat_message:([^\/]+)\/[^\/]+\z/.match(target)
          return "chat/#{chat[1]}" if chat

          target
        else
          channel = /\Achannel:([^\/]+)\/([^\/]+)\z/.match(target)
          return "team/#{channel[1]}/channel/#{channel[2]}" if channel

          chat = /\Achat:([^\/]+)\z/.match(target)
          return "chat/#{chat[1]}" if chat

          target
        end
      when "discord"
        match = /\A(?:message|channel):([^\/]+)(?:\/[^\/]+)?\z/.match(target)
        match ? "channel/#{match[1]}" : target
      else
        target # custom plugins can use an exact operator-allowlisted resource
      end
    end

    def oauth_plugin?(plugin)
      %w[jira_oauth teams_oauth].include?(plugin.to_s)
    end

    def oauth_provider_name(plugin)
      case plugin.to_s
      when "jira_oauth" then "atlassian"
      when "teams_oauth" then "microsoft"
      end
    end

    def self_actor_ids(plugin)
      ids = ENV.fetch("AICONSHELL_SELF_ACTOR_IDS", "").split(",").filter_map do |entry|
        provider, id = entry.strip.split(":", 2)
        id if provider == plugin.to_s && id.present?
      end
      ids << ENV["JIRA_SERVICE_ACCOUNT_ID"] if plugin.to_s == "jira" && ENV["JIRA_SERVICE_ACCOUNT_ID"].present?
      ids.uniq
    end
  end
end
